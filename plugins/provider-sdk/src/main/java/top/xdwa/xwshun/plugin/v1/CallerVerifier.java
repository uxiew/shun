// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 xwfe

package top.xdwa.xwshun.plugin.v1;

import android.content.Context;
import android.content.pm.PackageManager;
import android.os.Binder;

import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * 在 Binder 事务里核对「现在调我的是不是我信任的那个 App」。宿主和插件两边都用它。
 *
 * <p>用法：每个 AIDL 方法实现的<b>第一行</b>调 {@link #requireTrustedCaller()}，
 * 在任何 {@code Binder.clearCallingIdentity()} 之前。
 *
 * <p>为什么每个事务都查、而不是在 onBind 查一次：Binder 对象拿到手就能一直调，
 * 还能转交给别的 App；只在 onBind 查，后来谁拿着它都能用。
 * 为什么不信 Intent：extras 里的 calling_package 之类是对方随便写的字符串。
 *
 * <p>每次都重新读证书（不缓存）：包可能被卸载后装回另一张证书签的同名包。
 */
public final class CallerVerifier {
    private final PackageManager pm;
    private final String trustedPackage;
    private final Set<String> trustedSha256;

    /**
     * @param trustedPackage 允许的调用方包名（宿主或插件）
     * @param trustedSha256 允许的签名证书 SHA-256（小写十六进制）。调用方当前的每一张签名证书都必须在这里面。
     */
    public CallerVerifier(Context context, String trustedPackage, Set<String> trustedSha256) {
        if (trustedPackage == null || trustedPackage.isEmpty() || trustedSha256 == null || trustedSha256.isEmpty()) {
            throw new IllegalArgumentException("必须给出信任的包名和证书");
        }
        this.pm = context.getApplicationContext().getPackageManager();
        this.trustedPackage = trustedPackage;
        this.trustedSha256 = Collections.unmodifiableSet(new HashSet<>(trustedSha256));
    }

    /** @return 调用方 UID。不是信任的 App 时抛 SecurityException，调用方会在它那边收到这个异常。 */
    public int requireTrustedCaller() {
        int uid = Binder.getCallingUid();
        String[] packages = pm.getPackagesForUid(uid);
        if (packages == null || !Arrays.asList(packages).contains(trustedPackage)) {
            throw new SecurityException("调用方 UID " + uid + " 不是 " + trustedPackage);
        }
        List<SignerDigests.Cert> certs;
        long identity = Binder.clearCallingIdentity();
        try {
            certs = SignerDigests.of(pm, trustedPackage);
        } catch (PackageManager.NameNotFoundException e) {
            throw new SecurityException(trustedPackage + " 已不在设备上或不可见");
        } finally {
            Binder.restoreCallingIdentity(identity);
        }
        Set<String> actual = SignerDigests.digests(certs);
        if (actual.isEmpty() || !trustedSha256.containsAll(actual)) {
            throw new SecurityException(trustedPackage + " 的签名证书不是信任的那张");
        }
        return uid;
    }
}
