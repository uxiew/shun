package top.xdwa.shun

import com.yubico.yubikit.core.application.CommandState
import com.yubico.yubikit.core.fido.CtapException
import com.yubico.yubikit.core.fido.FidoConnection
import com.yubico.yubikit.core.smartcard.SmartCardConnection
import com.yubico.yubikit.fido.Cbor
import com.yubico.yubikit.fido.ctap.ClientPin
import com.yubico.yubikit.fido.ctap.CredentialManagement
import com.yubico.yubikit.fido.ctap.Ctap2Session
import com.yubico.yubikit.fido.ctap.PinUvAuthProtocol
import com.yubico.yubikit.fido.ctap.PinUvAuthProtocolV1
import com.yubico.yubikit.fido.ctap.PinUvAuthProtocolV2
import java.security.SecureRandom
import java.text.Normalizer

/**
 * 连上钥匙以后执行的那一次操作。和 Android 界面、广播都无关，所以 JVM 单测能用假连接 + 真的 [Ctap2Session] 测
 * （SecurityKeyOperationsTest）。错误码和 lib/domain/security_key.dart 的 SecurityKeyFailure 同名，改名字要两边一起改。
 */
object SecurityKeyOperations {
    const val CANCELLED = "cancelled"
    const val TIMEOUT = "timeout"
    const val PIN_REQUIRED = "pinRequired"
    const val PIN_INVALID = "pinInvalid"
    const val PIN_BLOCKED = "pinBlocked"
    const val PIN_NOT_SET = "pinNotSet"
    const val NO_CREDENTIAL = "noCredential"
    const val UNSUPPORTED = "unsupported"
    const val TRANSPORT = "transport"

    // 自己写数字：这几个在 CTAP2 规范里定死了，yubikit 的常量是 byte，放不进 when 分支。
    private const val ERR_OPERATION_DENIED = 0x27
    private const val ERR_KEEPALIVE_CANCEL = 0x2D
    private const val ERR_NO_CREDENTIALS = 0x2E
    private const val ERR_USER_ACTION_TIMEOUT = 0x2F
    private const val ERR_PIN_INVALID = 0x31
    private const val ERR_PIN_BLOCKED = 0x32
    private const val ERR_PIN_AUTH_INVALID = 0x33
    private const val ERR_PIN_AUTH_BLOCKED = 0x34
    private const val ERR_PIN_NOT_SET = 0x35
    private const val ERR_PUAT_REQUIRED = 0x36
    private const val ERR_PIN_TOKEN_EXPIRED = 0x38
    private const val ERR_ACTION_TIMEOUT = 0x3A
    private const val ERR_UV_BLOCKED = 0x3C
    private const val ERR_UNSUPPORTED_ALGORITHM = 0x26
    private const val ERR_UNSUPPORTED_OPTION = 0x2B

    private const val ALG_EDDSA = -8
    private const val ALG_ES256 = -7
    private const val CRED_PROTECT_UV_REQUIRED = 3

    /** PIN 错了时带上剩余次数；只有这一种错要查，另外请求一次钥匙。 */
    class PinInvalid(val retries: Int?) : CtapException(ERR_PIN_INVALID.toByte())

    fun errorCodeOf(error: CtapException): String =
        when (error.ctapError.toInt() and 0xFF) {
            ERR_OPERATION_DENIED, ERR_KEEPALIVE_CANCEL -> CANCELLED
            ERR_USER_ACTION_TIMEOUT, ERR_ACTION_TIMEOUT -> TIMEOUT
            ERR_NO_CREDENTIALS -> NO_CREDENTIAL
            ERR_PIN_INVALID -> PIN_INVALID
            ERR_PIN_BLOCKED, ERR_PIN_AUTH_BLOCKED, ERR_UV_BLOCKED -> PIN_BLOCKED
            ERR_PIN_NOT_SET -> PIN_NOT_SET
            ERR_PUAT_REQUIRED, ERR_PIN_AUTH_INVALID, ERR_PIN_TOKEN_EXPIRED -> PIN_REQUIRED
            ERR_UNSUPPORTED_ALGORITHM, ERR_UNSUPPORTED_OPTION -> UNSUPPORTED
            else -> TRANSPORT
        }

    fun retriesOf(error: CtapException): Int? = (error as? PinInvalid)?.retries

    sealed class Operation(val pin: CharArray?) {
        fun wipe() {
            pin?.fill('\u0000')
        }
    }

    class Sign(
        val rpId: String,
        val clientDataHash: ByteArray,
        val credentialId: ByteArray,
        val userPresence: Boolean,
        pin: CharArray?,
    ) : Operation(pin)

    class Create(
        val rpId: String,
        val resident: Boolean,
        val requirePin: Boolean,
        pin: CharArray?,
    ) : Operation(pin)

    class ListResident(pin: CharArray) : Operation(pin)

    fun parse(method: String?, arguments: Map<String, Any?>?): Operation {
        val args = arguments ?: throw IllegalArgumentException()
        val pin = (args["pin"] as? String)?.let(::normalizedPin)
        return when (method) {
            "sign" -> Sign(
                rpId = args["rpId"] as? String ?: throw IllegalArgumentException(),
                clientDataHash = args["clientDataHash"] as? ByteArray ?: throw IllegalArgumentException(),
                credentialId = args["credentialId"] as? ByteArray ?: throw IllegalArgumentException(),
                userPresence = args["userPresence"] != false,
                pin = pin,
            )
            "create" -> Create(
                rpId = args["rpId"] as? String ?: throw IllegalArgumentException(),
                resident = args["resident"] == true,
                requirePin = args["requirePin"] == true,
                pin = pin,
            )
            "listResident" -> ListResident(pin ?: throw IllegalArgumentException())
            else -> throw IllegalArgumentException()
        }
    }

    /**
     * CTAP2 规定 PIN 先做 Unicode NFC 规范化再编码，yubikit 不做。不做的话，带重音符的 PIN 在别的设备上设的，
     * 这里输入法给的是另一种编码的话，会被当成填错，白白消耗机会。
     */
    private fun normalizedPin(pin: String): CharArray =
        Normalizer.normalize(pin, Normalizer.Form.NFC).toCharArray()

    fun run(operation: Operation, connection: FidoConnection, state: CommandState): Map<String, Any?> =
        run(operation, Ctap2Session(connection), state)

    fun run(operation: Operation, connection: SmartCardConnection, state: CommandState): Map<String, Any?> =
        run(operation, Ctap2Session(connection), state)

    private fun run(operation: Operation, session: Ctap2Session, state: CommandState): Map<String, Any?> =
        when (operation) {
            is Sign -> sign(operation, session, state)
            is Create -> create(operation, session, state)
            is ListResident -> listResident(operation, session)
        }

    private fun sign(operation: Sign, session: Ctap2Session, state: CommandState): Map<String, Any?> {
        val auth = operation.pin?.let {
            pinAuth(session, it, ClientPin.PIN_PERMISSION_GA, operation.rpId)
        }
        val assertion = session.getAssertions(
            operation.rpId,
            operation.clientDataHash,
            listOf(mapOf("type" to "public-key", "id" to operation.credentialId)),
            null,
            // PIN 已经是用户验证，不再带 uv（规范禁止同时给）；up 照句柄里的 flags 走，和 ssh 命令一样。
            mapOf("up" to operation.userPresence),
            auth?.authenticate(operation.clientDataHash),
            auth?.version,
            state,
        ).first()
        return mapOf(
            "authenticatorData" to assertion.authenticatorData,
            "signature" to assertion.signature,
        )
    }

    private fun create(operation: Create, session: Ctap2Session, state: CommandState): Map<String, Any?> {
        val random = SecureRandom()
        val clientDataHash = ByteArray(32).also(random::nextBytes)
        val auth = operation.pin?.let {
            pinAuth(session, it, ClientPin.PIN_PERMISSION_MC, operation.rpId)
        }
        // resident 密钥按 rp + user.id 存：同一个用户 ID 会覆盖钥匙里已有的那把。ssh-keygen 默认全 0，
        // 它覆盖前会先问；这里不问，所以每次用随机 ID，永远不会冲掉用户已有的密钥。
        val userId = ByteArray(32).also(random::nextBytes)
        val extensions: Map<String, Any>? =
            if (operation.requirePin && session.cachedInfo.extensions.contains("credProtect")) {
                mapOf("credProtect" to CRED_PROTECT_UV_REQUIRED)
            } else {
                null
            }
        val credential = session.makeCredential(
            clientDataHash,
            mapOf("id" to operation.rpId, "name" to operation.rpId),
            mapOf("id" to userId, "name" to "openssh", "displayName" to "openssh"),
            // 这是偏好顺序：钥匙挑第一个它支持的，所以不支持 Ed25519 的老钥匙会给 ECDSA。
            listOf(
                mapOf("type" to "public-key", "alg" to ALG_EDDSA),
                mapOf("type" to "public-key", "alg" to ALG_ES256),
            ),
            null,
            extensions,
            if (operation.resident) mapOf("rk" to true) else null,
            auth?.authenticate(clientDataHash),
            auth?.version,
            null,
            state,
        )
        return mapOf("authenticatorData" to credential.authenticatorData)
    }

    private fun listResident(operation: ListResident, session: Ctap2Session): Map<String, Any?> {
        val info = session.cachedInfo
        if (!CredentialManagement.isSupported(info)) {
            throw CtapException(ERR_UNSUPPORTED_OPTION.toByte())
        }
        val pinAuth = pinAuth(session, operation.pin!!, ClientPin.PIN_PERMISSION_CM, null)
        val manager = CredentialManagement(session, pinAuth.protocol, pinAuth.token)
        if (manager.metadata.existingResidentCredentialsCount == 0) {
            return mapOf("credentials" to emptyList<Map<String, Any?>>())
        }
        val credentials = mutableListOf<Map<String, Any?>>()
        for (rp in manager.enumerateRps()) {
            val rpId = rp.rp["id"] as? String ?: continue
            if (!rpId.startsWith("ssh:")) continue
            for (credential in manager.enumerateCredentials(rp.rpIdHash)) {
                credentials += mapOf(
                    "rpId" to rpId,
                    "credentialId" to credential.credentialId["id"],
                    "publicKey" to Cbor.encode(credential.publicKey),
                )
            }
        }
        return mapOf("credentials" to credentials)
    }

    private class PinAuth(val protocol: PinUvAuthProtocol, val token: ByteArray) {
        val version: Int get() = protocol.version

        fun authenticate(message: ByteArray): ByteArray = protocol.authenticate(token, message)
    }

    private fun pinAuth(session: Ctap2Session, pin: CharArray, permission: Int, rpId: String?): PinAuth {
        val info = session.cachedInfo
        if (!ClientPin.isSupported(info)) throw CtapException(ERR_UNSUPPORTED_OPTION.toByte())
        val protocol: PinUvAuthProtocol =
            if (info.pinUvAuthProtocols.contains(2)) PinUvAuthProtocolV2() else PinUvAuthProtocolV1()
        val clientPin = ClientPin(session, protocol)
        val token = try {
            clientPin.getPinToken(pin, permission, rpId)
        } catch (error: CtapException) {
            if (error.ctapError.toInt() and 0xFF != ERR_PIN_INVALID) throw error
            throw PinInvalid(runCatching { clientPin.pinRetries.count }.getOrNull())
        } catch (_: IllegalArgumentException) {
            // yubikit 在发给钥匙之前就拒绝：短于 4 位或长于 63 字节。没消耗机会，不带次数。
            throw PinInvalid(null)
        }
        return PinAuth(protocol, token)
    }
}
