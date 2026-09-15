import 'package:flutter/material.dart';
import 'package:share_hub_media_sdk/share_hub_media_sdk.dart';

import 'ui/client_app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(ShareHubApp(appTitle: 'chuanchuan', previewEngine: createPreviewEngine()));
}
