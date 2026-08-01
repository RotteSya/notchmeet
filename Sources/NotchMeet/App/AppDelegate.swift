import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = AppController()
        controller.start()
        self.controller = controller
    }

    /// 录音中直接退出（菜单「退出」→ NSApp.terminate）不经过 stopRecording，
    /// 本场复盘会连同内存一起蒸发。
    func applicationWillTerminate(_ notification: Notification) {
        controller?.prepareForTermination()
    }
}
