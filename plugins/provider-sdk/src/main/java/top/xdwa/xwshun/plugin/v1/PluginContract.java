package top.xdwa.xwshun.plugin.v1;

/** 宿主与插件共用的常量。改这里等于改 API，要同步 docs/18。 */
public final class PluginContract {
    private PluginContract() {}

    /** 插件服务声明的 action。宿主的 {@code <queries>} 只查这一个，不申请 QUERY_ALL_PACKAGES。 */
    public static final String ACTION_PROVIDER = "top.xdwa.xwshun.plugin.action.PROVIDER_V1";

    /**
     * 插件服务上的 meta-data 名，值是指向 raw 资源的描述符 JSON。
     * 宿主不绑定服务、不执行插件任何代码就能读到它；批准之前只读这个。
     */
    public static final String META_DESCRIPTOR = "top.xdwa.xwshun.plugin.DESCRIPTOR";

    public static final int HOST_API_MAJOR = 1;
    public static final int HOST_API_MINOR = 0;

    /** 与 Dart 侧 plugin_api 的 maxDescriptorBytes 一致。 */
    public static final int MAX_DESCRIPTOR_BYTES = 16 * 1024;

    /** IXwshunHost.onProviderEvent 的 event 最大长度。 */
    public static final int MAX_EVENT_CHARS = 64;
}
