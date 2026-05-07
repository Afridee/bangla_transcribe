import UIKit
import Flutter
import Darwin

@UIApplicationMain
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    if let controller = window?.rootViewController as? FlutterViewController {
      FlutterMethodChannel(
        name: "bangla_transcribe/thermal_headroom",
        binaryMessenger: controller.binaryMessenger
      ).setMethodCallHandler { call, result in
        if call.method != "thermalHeadroomForWhisper" {
          result(FlutterMethodNotImplemented)
          return
        }
        switch ProcessInfo.processInfo.thermalState {
        case .nominal, .fair:
          result(true)
        default:
          result(false)
        }
      }

      FlutterMethodChannel(
        name: "bangla_transcribe/process_metrics",
        binaryMessenger: controller.binaryMessenger
      ).setMethodCallHandler { call, result in
        if call.method != "getSnapshot" {
          result(FlutterMethodNotImplemented)
          return
        }
        var map: [String: Any] = [:]
        let r = AppDelegate.currentRssBytes()
        if r >= 0 {
          map["rssBytes"] = r
        }
        let c = AppDelegate.cpuTimeMicros()
        if c >= 0 {
          map["cpuTimeMicros"] = c
        }
        let t = AppDelegate.machThreadCount()
        if t >= 0 {
          map["threadCount"] = t
        }
        result(map)
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private static func currentRssBytes() -> Int64 {
    var info = mach_task_basic_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
    )
    let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(
          mach_task_self_,
          task_flavor_t(MACH_TASK_BASIC_INFO),
          $0,
          &count
        )
      }
    }
    guard kerr == KERN_SUCCESS else { return -1 }
    return Int64(info.resident_size)
  }

  private static func cpuTimeMicros() -> Int64 {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return -1 }
    let u = Int64(usage.ru_utime.tv_sec) * 1_000_000 + Int64(usage.ru_utime.tv_usec)
    let s = Int64(usage.ru_stime.tv_sec) * 1_000_000 + Int64(usage.ru_stime.tv_usec)
    return u + s
  }

  private static func machThreadCount() -> Int {
    var threadList: thread_act_array_t?
    var threadCount: mach_msg_type_number_t = 0
    defer {
      if let list = threadList, threadCount > 0 {
        let byteSize = vm_size_t(threadCount) * vm_size_t(MemoryLayout<thread_t>.stride)
        vm_deallocate(
          mach_task_self_,
          vm_address_t(UInt(bitPattern: list)),
          byteSize
        )
      }
    }
    let kr = task_threads(mach_task_self_, &threadList, &threadCount)
    guard kr == KERN_SUCCESS else { return -1 }
    return Int(threadCount)
  }
}
