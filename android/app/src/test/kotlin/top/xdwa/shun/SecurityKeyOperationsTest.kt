package top.xdwa.shun

import com.yubico.yubikit.core.application.CommandState
import com.yubico.yubikit.core.fido.CtapException
import com.yubico.yubikit.core.fido.FidoConnection
import com.yubico.yubikit.fido.Cbor
import java.io.IOException
import java.math.BigInteger
import java.nio.ByteBuffer
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPublicKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.IvParameterSpec
import javax.crypto.spec.SecretKeySpec
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * 真的 yubikit [com.yubico.yubikit.fido.ctap.Ctap2Session] 对假钥匙：线上的 CTAPHID 分包、CBOR、PIN 协议都是真走的，只有钥匙是假的。
 * 只能证明我们传给库的参数对；真钥匙的行为是 SKY02–SKY04，这里过了不算那几条过。
 */
class SecurityKeyOperationsTest {
    private val rpId = "ssh:"
    private val hash = ByteArray(32) { it.toByte() }
    private val handle = ByteArray(20) { (it + 100).toByte() }

    private fun sign(pin: String? = null, presence: Boolean = true) = SecurityKeyOperations.Sign(
        rpId,
        hash,
        handle,
        presence,
        pin?.toCharArray(),
    )

    private fun run(key: FakeKey, operation: SecurityKeyOperations.Operation) =
        SecurityKeyOperations.run(operation, key, CommandState())

    @Test
    fun signWithoutPinPassesRpHashAndHandle() {
        val key = FakeKey()
        val value = run(key, sign())
        val request = key.lastAssertion!!
        assertEquals(rpId, request[1])
        assertArrayEquals(hash, request[2] as ByteArray)
        val allow = (request[3] as List<*>).single() as Map<*, *>
        assertEquals("public-key", allow["type"])
        assertArrayEquals(handle, allow["id"] as ByteArray)
        assertEquals(true, (request[5] as Map<*, *>)["up"])
        assertNull("没有 PIN 就不带 pinUvAuthParam", request[6])
        assertNull("没有 PIN 就不碰 clientPin", key.commands.firstOrNull { it == CMD_CLIENT_PIN })
        assertArrayEquals(key.authenticatorData, value["authenticatorData"] as ByteArray)
        assertArrayEquals(key.signature, value["signature"] as ByteArray)
    }

    @Test
    fun noTouchKeyAsksForNoPresence() {
        val key = FakeKey()
        run(key, sign(presence = false))
        assertEquals(false, (key.lastAssertion!![5] as Map<*, *>)["up"])
    }

    @Test
    fun signWithPinAuthenticatesTheHash() {
        val key = FakeKey()
        run(key, sign(pin = "1234"))
        val request = key.lastAssertion!!
        assertEquals(1, request[7])
        assertArrayEquals(key.authenticate(hash), request[6] as ByteArray)
        assertFalse("规范不让 uv 和 pinUvAuthParam 同时给", (request[5] as Map<*, *>).containsKey("uv"))
        assertEquals(2, key.lastTokenPermissions)
        assertEquals(rpId, key.lastTokenRpId)
    }

    @Test
    fun wrongPinReportsRetriesAndDoesNotRetryByItself() {
        val key = FakeKey()
        val error = assertThrows(CtapException::class.java) { run(key, sign(pin = "9999")) }
        assertEquals(SecurityKeyOperations.PIN_INVALID, SecurityKeyOperations.errorCodeOf(error))
        assertEquals(7, SecurityKeyOperations.retriesOf(error))
        assertEquals(1, key.pinAttempts)
        assertNull("PIN 错了就不应该去签名", key.lastAssertion)
    }

    @Test
    fun pinOutOfRangeNeverReachesTheKey() {
        val key = FakeKey()
        val error = assertThrows(CtapException::class.java) { run(key, sign(pin = "1".repeat(64))) }
        assertEquals(SecurityKeyOperations.PIN_INVALID, SecurityKeyOperations.errorCodeOf(error))
        assertNull(SecurityKeyOperations.retriesOf(error))
        assertEquals(0, key.pinAttempts)
    }

    @Test
    fun pinIsNormalizedToNfc() {
        val args = mapOf("pin" to "e\u0301pin")
        val parsed = SecurityKeyOperations.parse("listResident", args)
        assertEquals("\u00e9pin", String(parsed.pin!!))
    }

    @Test
    fun ctapErrorsMapToFailures() {
        val expected = mapOf(
            0x27 to SecurityKeyOperations.CANCELLED,
            0x2D to SecurityKeyOperations.CANCELLED,
            0x2E to SecurityKeyOperations.NO_CREDENTIAL,
            0x2F to SecurityKeyOperations.TIMEOUT,
            0x3A to SecurityKeyOperations.TIMEOUT,
            0x32 to SecurityKeyOperations.PIN_BLOCKED,
            0x34 to SecurityKeyOperations.PIN_BLOCKED,
            0x36 to SecurityKeyOperations.PIN_REQUIRED,
            0x35 to SecurityKeyOperations.PIN_NOT_SET,
            0x26 to SecurityKeyOperations.UNSUPPORTED,
            0x7F to SecurityKeyOperations.TRANSPORT,
        )
        for ((status, code) in expected) {
            val key = FakeKey().apply { assertionStatus = status }
            val error = assertThrows(CtapException::class.java) { run(key, sign()) }
            assertEquals("0x${status.toString(16)}", code, SecurityKeyOperations.errorCodeOf(error))
        }
    }

    @Test
    fun cutTransportIsAnIoError() {
        val key = FakeKey().apply { dropConnectionOnAssertion = true }
        assertThrows(IOException::class.java) { run(key, sign()) }
    }

    @Test
    fun createAsksForBothAlgorithmsAndNeverReusesAUserId() {
        val key = FakeKey()
        val first = run(key, SecurityKeyOperations.Create(rpId, false, false, null))
        val request = key.lastCreate!!
        assertEquals(rpId, (request[2] as Map<*, *>)["id"])
        val algorithms = (request[4] as List<*>).map { (it as Map<*, *>)["alg"] }
        assertEquals(listOf(-8, -7), algorithms)
        assertNull(request[6])
        assertNull(request[7])
        assertArrayEquals(key.authenticatorData, first["authenticatorData"] as ByteArray)

        val userId = (request[3] as Map<*, *>)["id"] as ByteArray
        run(key, SecurityKeyOperations.Create(rpId, false, false, null))
        val secondUserId = (key.lastCreate!![3] as Map<*, *>)["id"] as ByteArray
        assertFalse("同一个 user.id 会覆盖钥匙里已有的 resident", userId.contentEquals(secondUserId))
    }

    @Test
    fun createResidentWithPinAndCredProtect() {
        val key = FakeKey()
        run(key, SecurityKeyOperations.Create(rpId, true, true, "1234".toCharArray()))
        val request = key.lastCreate!!
        assertEquals(true, (request[7] as Map<*, *>)["rk"])
        assertEquals(3, (request[6] as Map<*, *>)["credProtect"])
        assertArrayEquals(key.authenticate(request[1] as ByteArray), request[8] as ByteArray)
        assertEquals(1, key.lastTokenPermissions)
    }

    @Test
    fun credProtectIsSkippedWhenTheKeyDoesNotSupportIt() {
        val key = FakeKey().apply { extensions = emptyList() }
        run(key, SecurityKeyOperations.Create(rpId, false, true, "1234".toCharArray()))
        assertNull(key.lastCreate!![6])
    }

    @Test
    fun listResidentKeepsOnlySshCredentials() {
        val key = FakeKey()
        val value = run(key, SecurityKeyOperations.ListResident("1234".toCharArray()))
        val credentials = value["credentials"] as List<*>
        // 同一个 rp 下两把都要读到：ConnectBot 报过只认出一把。
        assertEquals(2, credentials.size)
        val credential = credentials.first() as Map<*, *>
        assertEquals("ssh:", credential["rpId"])
        assertArrayEquals(handle, credential["credentialId"] as ByteArray)
        assertArrayEquals(
            ByteArray(20) { (it + 200).toByte() },
            (credentials.last() as Map<*, *>)["credentialId"] as ByteArray,
        )
        // 公钥翻回 CBOR，Dart 那头用同一套 CoseKey 解。
        val publicKey = Cbor.decode(credential["publicKey"] as ByteArray) as Map<*, *>
        assertEquals(-8, publicKey[3])
        assertEquals(4, key.lastTokenPermissions)
    }

    @Test
    fun listResidentOnEmptyKeyIsEmpty() {
        val key = FakeKey().apply { residentCount = 0 }
        val value = run(key, SecurityKeyOperations.ListResident("1234".toCharArray()))
        assertTrue((value["credentials"] as List<*>).isEmpty())
    }

    @Test
    fun listResidentOnOldKeyIsUnsupported() {
        val key = FakeKey().apply { credMgmt = false }
        val error = assertThrows(CtapException::class.java) {
            run(key, SecurityKeyOperations.ListResident("1234".toCharArray()))
        }
        assertEquals(SecurityKeyOperations.UNSUPPORTED, SecurityKeyOperations.errorCodeOf(error))
    }

    @Test
    fun pinOnAKeyWithoutClientPinIsUnsupported() {
        val key = FakeKey().apply { clientPin = false }
        val error = assertThrows(CtapException::class.java) { run(key, sign(pin = "1234")) }
        assertEquals(SecurityKeyOperations.UNSUPPORTED, SecurityKeyOperations.errorCodeOf(error))
    }

    @Test
    fun parseRejectsMissingFieldsAndWipeClearsThePin() {
        val args = mapOf(
            "rpId" to rpId,
            "clientDataHash" to hash,
            "credentialId" to handle,
            "userPresence" to false,
            "pin" to "1234",
        )
        val parsed = SecurityKeyOperations.parse("sign", args) as SecurityKeyOperations.Sign
        assertEquals(false, parsed.userPresence)
        assertNotNull(parsed.pin)
        parsed.wipe()
        assertTrue(parsed.pin!!.all { it == '\u0000' })

        assertThrows(IllegalArgumentException::class.java) {
            SecurityKeyOperations.parse("sign", args - "rpId")
        }
        assertThrows(IllegalArgumentException::class.java) {
            SecurityKeyOperations.parse("listResident", emptyMap())
        }
        assertThrows(IllegalArgumentException::class.java) {
            SecurityKeyOperations.parse("format", args)
        }
        assertThrows(IllegalArgumentException::class.java) {
            SecurityKeyOperations.parse("sign", null)
        }
    }

    private companion object {
        const val CMD_CLIENT_PIN = 0x06
    }

    /** 假钥匙：说真的 CTAPHID + CTAP2，PIN 协议用版本 1（AES-CBC + HMAC 前 16 字节）。 */
    private class FakeKey : FidoConnection {
        var clientPin = true
        var credMgmt = true
        var extensions = listOf("credProtect")
        var assertionStatus = 0
        var dropConnectionOnAssertion = false
        var residentCount = 2

        val commands = mutableListOf<Int>()
        var lastAssertion: Map<*, *>? = null
        var lastCreate: Map<*, *>? = null
        var lastTokenPermissions: Int? = null
        var lastTokenRpId: String? = null
        var pinAttempts = 0

        val authenticatorData = ByteArray(37) { 0x41 }
        val signature = ByteArray(64) { 0x42 }

        private val pin = "1234"
        private var retries = 8
        private val token = ByteArray(32).also(SecureRandom()::nextBytes)
        private val keyAgreement = KeyPairGenerator.getInstance("EC").run {
            initialize(ECGenParameterSpec("secp256r1"))
            generateKeyPair()
        }

        private val channel = 0x01020304
        private val outbound = ArrayDeque<ByteArray>()
        private var inboundCommand = 0
        private var inboundLength = 0
        private var inboundChannel = 0
        private var inbound = java.io.ByteArrayOutputStream()

        fun authenticate(message: ByteArray): ByteArray {
            val mac = Mac.getInstance("HmacSHA256")
            mac.init(SecretKeySpec(token, "HmacSHA256"))
            return mac.doFinal(message).copyOf(16)
        }

        override fun send(packet: ByteArray) {
            val buffer = ByteBuffer.wrap(packet)
            val cid = buffer.int
            val head = buffer.get().toInt() and 0xFF
            if (head and 0x80 != 0) {
                inboundChannel = cid
                inboundCommand = head
                inboundLength = buffer.short.toInt() and 0xFFFF
                inbound = java.io.ByteArrayOutputStream()
            }
            val take = minOf(buffer.remaining(), inboundLength - inbound.size())
            inbound.write(packet, buffer.position(), take)
            if (inbound.size() >= inboundLength) respond(inbound.toByteArray())
        }

        override fun receive(packet: ByteArray) {
            val next = outbound.removeFirstOrNull() ?: throw IOException("钥匙被拿走了")
            next.copyInto(packet)
        }

        override fun close() = Unit


        private fun respond(payload: ByteArray) {
            when (inboundCommand) {
                0x86 -> {
                    val body = ByteBuffer.allocate(17)
                        .put(payload, 0, 8)
                        .putInt(channel)
                        .put(2)
                        .put(5)
                        .put(4)
                        .put(0)
                        .put(0x04) // 支持 CBOR
                        .array()
                    frame(0x86, body)
                }
                0x90 -> {
                    val command = payload[0].toInt() and 0xFF
                    commands += command
                    val params = if (payload.size > 1) {
                        Cbor.decode(payload, 1, payload.size - 1) as Map<*, *>
                    } else {
                        emptyMap<Any, Any>()
                    }
                    val (status, body) = handle(command, params)
                    if (status < 0) return // 断开，什么都不回
                    val encoded = body?.let { Cbor.encode(it) } ?: ByteArray(0)
                    frame(0x90, byteArrayOf(status.toByte()) + encoded)
                }
                else -> frame(0xBF, byteArrayOf(1))
            }
        }

        private fun handle(command: Int, params: Map<*, *>): Pair<Int, Map<Int, Any?>?> = when (command) {
            0x04 -> 0 to getInfo()
            0x02 -> {
                val auth = params[6] as ByteArray?
                if (dropConnectionOnAssertion) {
                    -1 to null
                } else if (auth != null && !auth.contentEquals(authenticate(params[2] as ByteArray))) {
                    0x33 to null
                } else if (assertionStatus != 0) {
                    assertionStatus to null
                } else {
                    lastAssertion = params
                    0 to mapOf(
                        1 to mapOf("type" to "public-key", "id" to ByteArray(4)),
                        2 to authenticatorData,
                        3 to signature,
                    )
                }
            }
            0x01 -> {
                lastCreate = params
                0 to mapOf(
                    1 to "none",
                    2 to authenticatorData,
                    3 to emptyMap<String, Any>(),
                )
            }
            0x06 -> handlePin(params)
            0x0A -> handleCredentialManagement(params)
            else -> 0x01 to null
        }

        private fun getInfo(): Map<Int, Any?> = mapOf(
            1 to listOf("FIDO_2_0", "FIDO_2_1"),
            2 to extensions,
            3 to ByteArray(16),
            4 to buildMap<String, Boolean> {
                put("rk", true)
                put("up", true)
                if (clientPin) {
                    put("clientPin", true)
                    put("pinUvAuthToken", true)
                }
                if (credMgmt) put("credMgmt", true)
            },
            6 to listOf(1),
        )

        private fun handlePin(params: Map<*, *>): Pair<Int, Map<Int, Any?>?> {
            return when ((params[2] as Number).toInt()) {
                0x01 -> 0 to mapOf(3 to retries)
                0x02 -> {
                    val point = (keyAgreement.public as ECPublicKey).w
                    0 to mapOf(
                        1 to mapOf(
                            1 to 2,
                            3 to -25,
                            -1 to 1,
                            -2 to fixed(point.affineX),
                            -3 to fixed(point.affineY),
                        ),
                    )
                }
                0x05, 0x09 -> getToken(params)
                else -> 0x01 to null
            }
        }

        private fun getToken(params: Map<*, *>): Pair<Int, Map<Int, Any?>?> {
            val secret = sharedSecret(params[3] as Map<*, *>)
            val hash = MessageDigest.getInstance("SHA-256").digest(pin.toByteArray()).copyOf(16)
            pinAttempts += 1
            if (!aes(Cipher.DECRYPT_MODE, secret, params[6] as ByteArray).contentEquals(hash)) {
                retries -= 1
                return 0x31 to null
            }
            lastTokenPermissions = (params[9] as Number?)?.toInt()
            lastTokenRpId = params[10] as String?
            return 0 to mapOf(2 to aes(Cipher.ENCRYPT_MODE, secret, token))
        }

        private fun sharedSecret(peer: Map<*, *>): ByteArray {
            val params = (keyAgreement.public as ECPublicKey).params
            val publicKey = KeyFactory.getInstance("EC").generatePublic(
                ECPublicKeySpec(
                    ECPoint(
                        BigInteger(1, peer[-2] as ByteArray),
                        BigInteger(1, peer[-3] as ByteArray),
                    ),
                    params,
                ),
            )
            val agreement = KeyAgreement.getInstance("ECDH")
            agreement.init(keyAgreement.private)
            agreement.doPhase(publicKey, true)
            return MessageDigest.getInstance("SHA-256").digest(agreement.generateSecret())
        }

        private fun aes(mode: Int, key: ByteArray, data: ByteArray): ByteArray {
            val cipher = Cipher.getInstance("AES/CBC/NoPadding")
            cipher.init(mode, SecretKeySpec(key, "AES"), IvParameterSpec(ByteArray(16)))
            return cipher.doFinal(data)
        }

        private fun handleCredentialManagement(params: Map<*, *>): Pair<Int, Map<Int, Any?>?> {
            val publicKey = mapOf(1 to 1, 3 to -8, -1 to 6, -2 to ByteArray(32) { 9 })
            return when ((params[1] as Number).toInt()) {
                0x01 -> 0 to mapOf(1 to residentCount, 2 to 10)
                0x02 -> 0 to mapOf(3 to mapOf("id" to "ssh:"), 4 to ByteArray(32), 5 to 2)
                0x03 -> 0 to mapOf(3 to mapOf("id" to "github.com"), 4 to ByteArray(32) { 1 })
                0x04 -> 0 to mapOf(
                    6 to mapOf("id" to ByteArray(4)),
                    7 to mapOf("type" to "public-key", "id" to ByteArray(20) { (it + 100).toByte() }),
                    8 to publicKey,
                    9 to 2,
                )
                0x05 -> 0 to mapOf(
                    6 to mapOf("id" to ByteArray(4)),
                    7 to mapOf("type" to "public-key", "id" to ByteArray(20) { (it + 200).toByte() }),
                    8 to publicKey,
                )
                else -> 0x01 to null
            }
        }

        private fun fixed(value: BigInteger): ByteArray {
            val bytes = value.toByteArray()
            val result = ByteArray(32)
            val length = minOf(bytes.size, 32)
            bytes.copyInto(result, 32 - length, bytes.size - length, bytes.size)
            return result
        }

        private fun frame(command: Int, body: ByteArray) {
            var offset = 0
            var sequence = 0
            val id = if (inboundCommand == 0x86) inboundChannel else channel
            val first = ByteBuffer.allocate(FidoConnection.PACKET_SIZE)
                .putInt(id)
                .put(command.toByte())
                .putShort(body.size.toShort())
            val take = minOf(first.remaining(), body.size)
            first.put(body, 0, take)
            outbound.addLast(first.array())
            offset += take
            while (offset < body.size) {
                val next = ByteBuffer.allocate(FidoConnection.PACKET_SIZE)
                    .putInt(id)
                    .put(sequence++.toByte())
                val size = minOf(next.remaining(), body.size - offset)
                next.put(body, offset, size)
                outbound.addLast(next.array())
                offset += size
            }
        }
    }
}
