// AIC06 的假模型接口：让容器里真的 Claude Code、Codex 跑起来，但不连真实账号、不花额度。
// 只监听容器里的 127.0.0.1:18080，外面连不到。由 mock-model.sh 拷进容器并启动，不进镜像，
// 所以 R20 的 TER13（未登录欢迎页）不受影响。
//
// 回话规则是固定的，测试靠它判断「续上的是不是同一段对话」：
//   用户这句里有 MOCK-REMEMBER <口令>  → 回 OK <口令>
//   用户这句里有 MOCK-RECALL <标签>    → 去这次请求带的历史里找 MOCK-REMEMBER，回 RECALL <标签> <口令>，找不到回 RECALL <标签> NONE
//                                     （标签可省。续上旧对话时工具会把以前的回复重画一遍，每次带不同标签，屏幕上才分得出哪句是新回的）
//   其他                               → 回 MOCK-REPLY
// 工具自己不把历史发过来，就答不出口令，所以 RECALL 对了说明工具确实从自己的会话记录里续上了。
//
// 每个请求往 ~/mock-model/requests.jsonl 记一行：接口、工具声称的会话 ID、历史条数、回了什么。
// 不记提示词全文（只截口令那一段），也不记任何请求头里的密钥。
import { createServer } from 'node:http';
import { appendFileSync, mkdirSync } from 'node:fs';
import { homedir } from 'node:os';

const port = Number(process.env.MOCK_MODEL_PORT || 18080);
const dir = `${homedir()}/mock-model`;
mkdirSync(dir, { recursive: true });
const log = (entry) =>
  appendFileSync(`${dir}/requests.jsonl`, JSON.stringify({ at: new Date().toISOString(), ...entry }) + '\n');

// Claude Code 会在用户消息里夹 <system-reminder>，里面可能复述别的内容；只看用户自己打的字。
const stripReminders = (text) => text.replace(/<system-reminder>[\s\S]*?<\/system-reminder>/g, '');

function textOf(content) {
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';
  return content
    .map((part) => (part.type === 'text' || part.type === 'input_text' ? part.text || '' : ''))
    .join('\n');
}

/** [userTexts] 按顺序是这次请求里所有用户消息，最后一条是刚打的那句。 */
function reply(userTexts) {
  const last = stripReminders(userTexts.at(-1) || '');
  const remember = last.match(/MOCK-REMEMBER (\S+)/);
  if (remember) return { text: `OK ${remember[1]}`, rule: 'remember', token: remember[1] };
  const recall = last.match(/MOCK-RECALL(?: (\S+))?/);
  if (recall) {
    const tag = recall[1] ? `${recall[1]} ` : '';
    for (const earlier of userTexts.slice(0, -1).reverse()) {
      const found = stripReminders(earlier).match(/MOCK-REMEMBER (\S+)/);
      if (found) return { text: `RECALL ${tag}${found[1]}`, rule: 'recall', token: found[1] };
    }
    return { text: `RECALL ${tag}NONE`, rule: 'recall', token: null };
  }
  return { text: 'MOCK-REPLY', rule: 'other', token: null };
}

const sse = (res, event, data) => res.write(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
let counter = 0;

function anthropic(req, res, body) {
  const messages = Array.isArray(body.messages) ? body.messages : [];
  const users = messages.filter((m) => m.role === 'user').map((m) => textOf(m.content));
  const answer = reply(users);
  // metadata.user_id 里带着 Claude Code 自己的会话 ID（…_session_<uuid>），这是核对「续的是哪段」的另一条独立证据。
  const session = String(body.metadata?.user_id || '').match(/session_([0-9a-f-]{36})/)?.[1] || null;
  log({
    api: 'anthropic',
    model: body.model,
    // 主对话带 tools；起标题、判断话题之类的辅助请求不带。测试只看主对话。
    main: Array.isArray(body.tools) && body.tools.length > 0,
    session,
    headerSession: req.headers['x-claude-code-session-id'] || null,
    userMessages: users.length,
    rule: answer.rule,
    token: answer.token,
    reply: answer.text,
  });
  const id = `msg_mock_${++counter}`;
  const usage = { input_tokens: 1, output_tokens: 1 };
  if (!body.stream) {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({
      id, type: 'message', role: 'assistant', model: body.model,
      content: [{ type: 'text', text: answer.text }],
      stop_reason: 'end_turn', stop_sequence: null, usage,
    }));
    return;
  }
  res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' });
  sse(res, 'message_start', {
    type: 'message_start',
    message: { id, type: 'message', role: 'assistant', model: body.model, content: [],
      stop_reason: null, stop_sequence: null, usage },
  });
  sse(res, 'content_block_start', { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } });
  sse(res, 'content_block_delta', { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: answer.text } });
  sse(res, 'content_block_stop', { type: 'content_block_stop', index: 0 });
  sse(res, 'message_delta', { type: 'message_delta', delta: { stop_reason: 'end_turn', stop_sequence: null }, usage: { output_tokens: 1 } });
  sse(res, 'message_stop', { type: 'message_stop' });
  res.end();
}

function openai(req, res, body) {
  const input = Array.isArray(body.input) ? body.input : [];
  const users = input
    .filter((item) => (item.type === 'message' || item.type === undefined) && item.role === 'user')
    .map((item) => textOf(item.content));
  const answer = reply(users);
  log({
    api: 'openai',
    model: body.model,
    // 同 Claude：主对话带 tools，辅助请求不带。
    main: Array.isArray(body.tools) && body.tools.length > 0,
    // Codex 0.166 把自己的会话 ID 放在 prompt_cache_key 里，和 ~/.codex/sessions 下 rollout 文件名末尾的 ID 一致。
    // 请求头里带不带、叫什么各版本不一样，只记头的名字和值里的 ID，不记别的头。
    session: body.prompt_cache_key || null,
    sessionHeaders: Object.fromEntries(
      Object.entries(req.headers).filter(([name]) => /session|conversation|thread/i.test(name))),
    userMessages: users.length,
    rule: answer.rule,
    token: answer.token,
    reply: answer.text,
  });
  const responseId = `resp_mock_${++counter}`;
  const itemId = `msg_mock_${counter}`;
  const item = { type: 'message', id: itemId, role: 'assistant', status: 'completed',
    content: [{ type: 'output_text', text: answer.text, annotations: [] }] };
  res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' });
  sse(res, 'response.created', { type: 'response.created', response: { id: responseId, status: 'in_progress' } });
  sse(res, 'response.output_item.added', { type: 'response.output_item.added', output_index: 0,
    item: { ...item, status: 'in_progress', content: [] } });
  sse(res, 'response.output_text.delta', { type: 'response.output_text.delta', item_id: itemId,
    output_index: 0, content_index: 0, delta: answer.text });
  sse(res, 'response.output_item.done', { type: 'response.output_item.done', output_index: 0, item });
  sse(res, 'response.completed', { type: 'response.completed', response: {
    id: responseId, status: 'completed', output: [item],
    usage: { input_tokens: 1, input_tokens_details: { cached_tokens: 0 }, output_tokens: 1,
      output_tokens_details: { reasoning_tokens: 0 }, total_tokens: 2 },
  } });
  res.end();
}

createServer((req, res) => {
  const chunks = [];
  req.on('data', (chunk) => chunks.push(chunk));
  req.on('end', () => {
    const path = (req.url || '').split('?')[0];
    let body = {};
    try {
      body = chunks.length ? JSON.parse(Buffer.concat(chunks).toString('utf8')) : {};
    } catch {
      body = {};
    }
    if (req.method === 'POST' && path === '/v1/messages') return anthropic(req, res, body);
    if (req.method === 'POST' && path === '/v1/messages/count_tokens') {
      res.writeHead(200, { 'content-type': 'application/json' });
      return res.end(JSON.stringify({ input_tokens: 1 }));
    }
    if (req.method === 'POST' && path === '/v1/responses') return openai(req, res, body);
    // 别的接口（模型列表、遥测之类）一律 404，并记下来：工具要是因为缺某个接口起不来，日志里看得到是哪个。
    log({ api: 'unknown', method: req.method, path });
    res.writeHead(404, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ error: { type: 'not_found', message: `mock has no ${path}` } }));
  });
}).listen(port, '127.0.0.1', () => console.log(`mock model on 127.0.0.1:${port}`));
