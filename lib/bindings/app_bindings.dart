import 'package:get/get.dart';

import '../services/last_model_audio_sample_service.dart';
import '../services/recording_service.dart';
import '../services/transcription_resource_monitor.dart';
import '../services/transcription_service.dart';

class AppBindings extends Bindings {
  @override
  void dependencies() {
    Get.put<TranscriptionResourceMonitorService>(
      TranscriptionResourceMonitorService(),
      permanent: true,
    );
    Get.put<TranscriptionService>(TranscriptionService(), permanent: true);
    Get.put<RecordingService>(RecordingService(), permanent: true);
    Get.put<LastModelAudioSampleService>(
      LastModelAudioSampleService(),
      permanent: true,
    );
  }
}
