import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

bool get isWindowsDesktop => !kIsWeb && Platform.isWindows;

bool get isMobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

/// Phone/tablet always use the mobile shell (even in landscape).
/// Windows uses a width breakpoint for narrow vs wide desktop chrome.
bool isCompactLayout(double width) => isMobile || width < 720;
