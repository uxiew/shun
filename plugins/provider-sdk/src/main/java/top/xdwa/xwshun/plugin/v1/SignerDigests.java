// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 xwfe

package top.xdwa.xwshun.plugin.v1;

import android.annotation.SuppressLint;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.pm.Signature;
import android.content.pm.SigningInfo;
import android.os.Build;

import java.io.ByteArrayInputStream;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.security.cert.CertificateException;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

import javax.security.auth.x500.X500Principal;

/**
 * 从系统读出某个已安装包的<b>当前</b>签名证书。宿主和插件互相认人都只信这里的结果，
 * 不信描述符、Intent 或对方自报的任何「证书」字段。
 *
 * <p>只取当前签名者（API 28+ 的 getApkContentsSigners），不把签名轮换历史里的旧证书算进来：
 * 作者轮换了密钥，宿主会看到「证书变了」，需要用户重新核验，而不是自动接受（docs/plugin-authors/compatibility.md「签名密钥」）。
 */
public final class SignerDigests {
    private SignerDigests() {}

    public static final class Cert {
        /** 证书 DER 的 SHA-256，小写十六进制，不带分隔符。 */
        public final String sha256;

        /**
         * 是不是 Android SDK 自动生成的调试证书（主题 CN=Android Debug,O=Android,C=US）。
         * release 宿主不接受这类证书签的插件：每台开发机都有一张，谁都能拿来签。
         */
        public final boolean androidDebug;

        Cert(String sha256, boolean androidDebug) {
            this.sha256 = sha256;
            this.androidDebug = androidDebug;
        }
    }

    /**
     * @throws PackageManager.NameNotFoundException 包没装，或者对调用方不可见（Android 11+ 的包可见性）
     */
    @SuppressLint("PackageManagerGetSignatures") // API 24–27 只能这样取；那几版没有 GET_SIGNATURES 的伪造问题（修于 4.4）
    public static List<Cert> of(PackageManager pm, String packageName)
            throws PackageManager.NameNotFoundException {
        Signature[] signatures;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageInfo info = pm.getPackageInfo(packageName, PackageManager.GET_SIGNING_CERTIFICATES);
            SigningInfo signing = info.signingInfo;
            signatures = signing == null ? null : signing.getApkContentsSigners();
        } else {
            PackageInfo info = pm.getPackageInfo(packageName, PackageManager.GET_SIGNATURES);
            signatures = info.signatures;
        }
        if (signatures == null || signatures.length == 0) {
            return Collections.emptyList();
        }
        List<Cert> certs = new ArrayList<>(signatures.length);
        for (Signature signature : signatures) {
            byte[] der = signature.toByteArray();
            certs.add(new Cert(sha256(der), isAndroidDebug(der)));
        }
        return Collections.unmodifiableList(certs);
    }

    public static Set<String> digests(List<Cert> certs) {
        Set<String> out = new HashSet<>();
        for (Cert cert : certs) out.add(cert.sha256);
        return out;
    }

    static String sha256(byte[] der) {
        try {
            byte[] hash = MessageDigest.getInstance("SHA-256").digest(der);
            StringBuilder hex = new StringBuilder(hash.length * 2);
            for (byte b : hash) hex.append(String.format("%02x", b & 0xff));
            return hex.toString();
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }

    private static final Set<String> DEBUG_SUBJECT =
            new HashSet<>(Arrays.asList("CN=Android Debug", "O=Android", "C=US"));

    static boolean isAndroidDebug(byte[] der) {
        try {
            X509Certificate cert = (X509Certificate) CertificateFactory.getInstance("X.509")
                    .generateCertificate(new ByteArrayInputStream(der));
            String subject = cert.getSubjectX500Principal().getName(X500Principal.RFC2253);
            return new HashSet<>(Arrays.asList(subject.split(","))).equals(DEBUG_SUBJECT);
        } catch (CertificateException | ClassCastException e) {
            return false;
        }
    }
}
