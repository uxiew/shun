// Tailscale SSH 认证行为的本机仿制服务器（R14 测试用，不是 Tailscale）。
//
// 认证回调的结构照 tailscale v1.104.0（c8125a97）ssh/tailssh/tailssh.go 的 ServerConfig / clientAuth 写：
// none、密码、公钥三种请求都进同一个 clientAuth，密码和公钥的内容一概不看；
// 拒绝时先发 banner，再返回空的 PartialSuccessError（tailssh 的 errTerminal）——
// x/crypto v0.57.0 收到它不回 USERAUTH_FAILURE，直接断 TCP。
// SSH 库用和 tailscale v1.104.0 相同的 golang.org/x/crypto v0.57.0，所以线上字节是同一个库发的。
// tailssh.go 版权归 Tailscale Inc & AUTHORS，BSD-3-Clause。
//
// 不一样的地方：控制面（策略、check 的批准）换成本机 HTTP 开关；登录后的 shell 是假的，
// 只会回答 tty、whoami、exit。check banner 的文字取自 Tailscale 官方文档的截图和用户报告，
// 真实控制面发什么由 Tailscale 服务器决定，客户端源码里没有。
package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"
)

// 和 tailssh 一样：空的 PartialSuccessError 表示「到此为止，别再试别的方法」。
var errTerminal = &ssh.PartialSuccessError{Next: ssh.ServerAuthCallbacks{}}

type event struct {
	Time   time.Time `json:"time"`
	Conn   int       `json:"conn"`
	Kind   string    `json:"kind"`
	User   string    `json:"user,omitempty"`
	Method string    `json:"method,omitempty"`
	// 收到的密码长度、公钥指纹：用来证明「客户端发没发」，不记密码本身。
	PasswordLen int    `json:"passwordLen,omitempty"`
	PublicKey   string `json:"publicKey,omitempty"`
	Detail      string `json:"detail,omitempty"`
}

type check struct {
	ID       string `json:"id"`
	Conn     int    `json:"conn"`
	User     string `json:"user"`
	decision chan string
}

type fixture struct {
	mu        sync.Mutex
	events    []event
	checks    map[string]*check
	nextConn  int
	holdLimit time.Duration
}

func (f *fixture) record(e event) {
	e.Time = time.Now()
	f.mu.Lock()
	f.events = append(f.events, e)
	f.mu.Unlock()
	line, _ := json.Marshal(e)
	log.Printf("%s", line)
}

// 场景按 SSH 用户名选：一个连接一个场景，测试并发跑也不会串。真实 Tailscale 里用户名只决定登录成哪个本地用户。
var evilLinks = map[string]string{
	"evil-domain":   "https://login.tailscale.com.evil.example/a/abcdef123456",
	"evil-http":     "http://login.tailscale.com/a/abcdef123456",
	"evil-two":      "https://login.tailscale.com/a/abcdef123456 https://evil.example/a/abcdef123456",
	"evil-intent":   "intent://login.tailscale.com/a/abcdef123456#Intent;scheme=https;package=evil.example;end",
	"evil-userinfo": "https://login.tailscale.com@evil.example/a/abcdef123456",
	"evil-path":     "https://login.tailscale.com/admin/settings/keys?x=1",
	"evil-bidi":     "https://login.tailscale.com/a/abc‮def",
	"evil-port":     "https://login.tailscale.com:8443/a/abcdef123456",
	"headscale":     "http://headscale.fixture.internal:8080/auth/hskey-authreq-AbCdEfGhIjKlMnOpQrStUvWx",
}

type conn struct {
	f    *fixture
	id   int
	spac ssh.ServerPreAuthConn
}

func (c *conn) banner(text string) error {
	c.f.record(event{Conn: c.id, Kind: "banner", Detail: text})
	return c.spac.SendAuthBanner(text)
}

func (c *conn) errDenied(message string) error {
	if message == "" {
		message = "tailscale: access denied"
	}
	c.banner(message)
	return errTerminal
}

func (c *conn) errBanner(message string) error {
	c.banner("tailscale: " + message + "\n")
	return errTerminal
}

func randomHex(n int) string {
	b := make([]byte, n)
	rand.Read(b)
	return hex.EncodeToString(b)
}

// clientAuth 对应 tailssh 的 clientAuth：按「策略」接受、拒绝或挂起等 check。
func (c *conn) clientAuth(cm ssh.ConnMetadata, method string) (*ssh.Permissions, error) {
	user := cm.User()
	switch {
	case user == "accept":
		c.f.record(event{Conn: c.id, Kind: "accept", User: user, Method: method})
		return &ssh.Permissions{}, nil
	case user == "reject":
		c.f.record(event{Conn: c.id, Kind: "reject", User: user, Method: method})
		return nil, c.errBanner("tailnet policy does not permit you to SSH to this node")
	case user == "check" || evilLinks[user] != "":
		link := evilLinks[user]
		if link == "" {
			link = "https://login.tailscale.com/a/" + randomHex(6)
		}
		// HoldAndDelegate 的 Message：先发 banner，再挂住这次认证请求等控制面回话。
		if err := c.banner("# Tailscale SSH requires an additional check.\n# To authenticate, visit: " + link + "\n"); err != nil {
			return nil, errTerminal
		}
		ck := &check{ID: randomHex(8), Conn: c.id, User: user, decision: make(chan string, 1)}
		c.f.mu.Lock()
		c.f.checks[ck.ID] = ck
		c.f.mu.Unlock()
		c.f.record(event{Conn: c.id, Kind: "hold", User: user, Method: method, Detail: ck.ID})
		defer func() {
			c.f.mu.Lock()
			delete(c.f.checks, ck.ID)
			c.f.mu.Unlock()
		}()
		select {
		case d := <-ck.decision:
			c.f.record(event{Conn: c.id, Kind: "decision", User: user, Detail: d})
			if d == "approve" {
				if err := c.banner("# Authentication checked with Tailscale SSH.\n# Time since last authentication: 0s\n"); err != nil {
					return nil, errTerminal
				}
				return &ssh.Permissions{}, nil
			}
			return nil, c.errDenied("")
		case <-time.After(c.f.holdLimit):
			c.f.record(event{Conn: c.id, Kind: "hold-expired", User: user})
			return nil, c.errBanner("failed to fetch next SSH action")
		}
	default:
		return nil, c.errBanner(fmt.Sprintf("tailnet policy does not permit you to SSH as user %q", user))
	}
}

func (f *fixture) serverConfig(c *conn, hostKey ssh.Signer) *ssh.ServerConfig {
	cfg := &ssh.ServerConfig{
		ServerVersion: "SSH-2.0-Tailscale",
		PreAuthConnCallback: func(spac ssh.ServerPreAuthConn) {
			c.spac = spac
		},
		NoClientAuth: true,
		NoClientAuthCallback: func(cm ssh.ConnMetadata) (*ssh.Permissions, error) {
			f.record(event{Conn: c.id, Kind: "auth", User: cm.User(), Method: "none"})
			return c.clientAuth(cm, "none")
		},
		PasswordCallback: func(cm ssh.ConnMetadata, pword []byte) (*ssh.Permissions, error) {
			f.record(event{Conn: c.id, Kind: "auth", User: cm.User(), Method: "password", PasswordLen: len(pword)})
			return c.clientAuth(cm, "password")
		},
		PublicKeyCallback: func(cm ssh.ConnMetadata, key ssh.PublicKey) (*ssh.Permissions, error) {
			f.record(event{Conn: c.id, Kind: "auth", User: cm.User(), Method: "publickey", PublicKey: ssh.FingerprintSHA256(key)})
			return c.clientAuth(cm, "publickey")
		},
	}
	cfg.AddHostKey(hostKey)
	return cfg
}

func (f *fixture) handle(nc net.Conn, hostKey ssh.Signer) {
	defer nc.Close()
	f.mu.Lock()
	f.nextConn++
	c := &conn{f: f, id: f.nextConn}
	f.mu.Unlock()
	f.record(event{Conn: c.id, Kind: "connect", Detail: nc.RemoteAddr().String()})
	sc, chans, reqs, err := ssh.NewServerConn(nc, f.serverConfig(c, hostKey))
	if err != nil {
		f.record(event{Conn: c.id, Kind: "closed-before-auth", Detail: err.Error()})
		return
	}
	defer sc.Close()
	f.record(event{Conn: c.id, Kind: "authenticated", User: sc.User()})
	go ssh.DiscardRequests(reqs)
	for nch := range chans {
		if nch.ChannelType() != "session" {
			nch.Reject(ssh.UnknownChannelType, "fixture only supports sessions")
			continue
		}
		ch, in, err := nch.Accept()
		if err != nil {
			continue
		}
		go f.session(c, sc.User(), ch, in)
	}
	f.record(event{Conn: c.id, Kind: "closed"})
}

// 假 shell：不执行任何东西，只回答 tty / whoami / exit。
func (f *fixture) session(c *conn, user string, ch ssh.Channel, in <-chan *ssh.Request) {
	defer ch.Close()
	exit := func(code uint32) {
		ch.SendRequest("exit-status", false, ssh.Marshal(struct{ Code uint32 }{code}))
	}
	answer := func(cmd string) (string, bool) {
		switch strings.TrimSpace(cmd) {
		case "tty":
			return "/dev/pts/9", true
		case "whoami":
			return user, true
		case "":
			return "", true
		}
		return "fixture: not a real shell", false
	}
	for req := range in {
		switch req.Type {
		case "pty-req", "env", "window-change":
			req.Reply(true, nil)
		case "exec":
			var payload struct{ Command string }
			ssh.Unmarshal(req.Payload, &payload)
			req.Reply(true, nil)
			f.record(event{Conn: c.id, Kind: "exec", Detail: payload.Command})
			out, ok := answer(payload.Command)
			ch.Write([]byte(out + "\n"))
			if ok {
				exit(0)
			} else {
				exit(127)
			}
			return
		case "shell":
			req.Reply(true, nil)
			f.record(event{Conn: c.id, Kind: "shell"})
			go func() {
				for range in {
				}
			}()
			ch.Write([]byte("Tailscale SSH fixture (not a real shell)\r\n$ "))
			line := []byte{}
			buf := make([]byte, 256)
			for {
				n, err := ch.Read(buf)
				if err != nil {
					return
				}
				for _, b := range buf[:n] {
					switch b {
					case '\r', '\n':
						cmd := string(line)
						line = line[:0]
						if strings.TrimSpace(cmd) == "exit" {
							ch.Write([]byte("\r\nlogout\r\n"))
							exit(0)
							return
						}
						out, _ := answer(cmd)
						if out != "" {
							out += "\r\n"
						}
						ch.Write([]byte("\r\n" + out + "$ "))
					default:
						line = append(line, b)
						ch.Write([]byte{b})
					}
				}
			}
		default:
			req.Reply(false, nil)
		}
	}
}

func (f *fixture) control(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	path := strings.Trim(r.URL.Path, "/")
	parts := strings.Split(path, "/")
	switch {
	case r.Method == http.MethodGet && path == "events":
		f.mu.Lock()
		defer f.mu.Unlock()
		json.NewEncoder(w).Encode(f.events)
	case r.Method == http.MethodGet && path == "checks":
		f.mu.Lock()
		list := []*check{}
		for _, ck := range f.checks {
			list = append(list, ck)
		}
		f.mu.Unlock()
		json.NewEncoder(w).Encode(list)
	case r.Method == http.MethodPost && len(parts) == 3 && parts[0] == "checks" && (parts[2] == "approve" || parts[2] == "deny"):
		f.mu.Lock()
		ck := f.checks[parts[1]]
		f.mu.Unlock()
		if ck == nil {
			w.WriteHeader(http.StatusNotFound)
			fmt.Fprint(w, `{"error":"no such pending check"}`)
			return
		}
		select {
		case ck.decision <- parts[2]:
			fmt.Fprint(w, `{"ok":true}`)
		default:
			w.WriteHeader(http.StatusConflict)
			fmt.Fprint(w, `{"error":"already decided"}`)
		}
	default:
		w.WriteHeader(http.StatusNotFound)
		fmt.Fprint(w, `{"error":"unknown endpoint"}`)
	}
}

func main() {
	listen := flag.String("listen", "127.0.0.1:0", "SSH 监听地址（只绑回环）")
	controlAddr := flag.String("control", "127.0.0.1:0", "控制面 HTTP 监听地址（只绑回环）")
	stateFile := flag.String("state", "", "启动后把端口和主机指纹写进这个 JSON 文件")
	holdLimit := flag.Duration("hold-limit", 30*time.Minute, "check 挂起多久后自己放弃（tailssh 是 30 分钟）")
	flag.Parse()
	for _, addr := range []string{*listen, *controlAddr} {
		host, _, err := net.SplitHostPort(addr)
		if err != nil || !net.ParseIP(host).IsLoopback() {
			log.Fatalf("只允许绑回环地址：%s", addr)
		}
	}

	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		log.Fatal(err)
	}
	hostKey, err := ssh.NewSignerFromKey(priv)
	if err != nil {
		log.Fatal(err)
	}
	f := &fixture{checks: map[string]*check{}, holdLimit: *holdLimit}

	sshLn, err := net.Listen("tcp", *listen)
	if err != nil {
		log.Fatal(err)
	}
	ctlLn, err := net.Listen("tcp", *controlAddr)
	if err != nil {
		log.Fatal(err)
	}
	state := map[string]any{
		"sshPort":            sshLn.Addr().(*net.TCPAddr).Port,
		"controlPort":        ctlLn.Addr().(*net.TCPAddr).Port,
		"fingerprintSha256":  ssh.FingerprintSHA256(hostKey.PublicKey()),
		"hostKeyType":        hostKey.PublicKey().Type(),
		"pid":                os.Getpid(),
		"tailscaleReference": "tailscale v1.104.0 c8125a977e8714ac9f0d1a1fb43c714490d38bd3",
	}
	encoded, _ := json.Marshal(state)
	if *stateFile != "" {
		if err := os.WriteFile(*stateFile, encoded, 0o600); err != nil {
			log.Fatal(err)
		}
	}
	fmt.Println(string(encoded))

	go http.Serve(ctlLn, http.HandlerFunc(f.control))
	for {
		nc, err := sshLn.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return
			}
			log.Print(err)
			continue
		}
		go f.handle(nc, hostKey)
	}
}
