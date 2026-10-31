package top.xdwa.shun

import org.junit.Assert.assertEquals
import org.junit.Test

// 手上只有 API 30 的模拟器，其它版本走哪条路在这里钉住。页面真弹不弹要在那个版本上看。
class AppLockRouteTest {
    @Test
    fun api30AndUpUseAuthenticators() {
        for (sdk in 30..36) {
            assertEquals(AuthRoute.PROMPT_AUTHENTICATORS, authRoute(sdk, pinOnly = false))
            assertEquals(AuthRoute.PROMPT_AUTHENTICATORS, authRoute(sdk, pinOnly = true))
        }
    }

    @Test
    fun api29AllowsCredentialFallback() {
        assertEquals(AuthRoute.PROMPT_CREDENTIAL_ALLOWED, authRoute(29, pinOnly = false))
        assertEquals(AuthRoute.CONFIRM_CREDENTIAL, authRoute(29, pinOnly = true))
    }

    @Test
    fun api28FallsBackToConfirmPage() {
        assertEquals(AuthRoute.PROMPT_THEN_CONFIRM, authRoute(28, pinOnly = false))
        assertEquals(AuthRoute.CONFIRM_CREDENTIAL, authRoute(28, pinOnly = true))
    }

    @Test
    fun belowApi28OnlyHasConfirmPage() {
        for (sdk in 24..27) {
            assertEquals(AuthRoute.CONFIRM_CREDENTIAL, authRoute(sdk, pinOnly = false))
            assertEquals(AuthRoute.CONFIRM_CREDENTIAL, authRoute(sdk, pinOnly = true))
        }
    }

    @Test
    fun authenticatorsFollowTheSettings() {
        val weak = 0x00FF
        val strong = 0x000F
        val credential = 0x8000
        assertEquals(credential, allowedAuthenticators(true, true, weak, strong, credential))
        assertEquals(credential, allowedAuthenticators(true, false, weak, strong, credential))
        assertEquals(weak or credential, allowedAuthenticators(false, true, weak, strong, credential))
        assertEquals(strong or credential, allowedAuthenticators(false, false, weak, strong, credential))
    }
}
