/// Opening the studio's booking page in the phone's browser.
library;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'config.dart';

Future<void> openSchedule(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  var ok = false;
  try {
    ok = await launchUrl(Uri.parse(AppConfig.scheduleUrl), mode: LaunchMode.externalApplication);
  } catch (_) {}
  if (!ok) messenger.showSnackBar(const SnackBar(content: Text("Couldn't open the booking page. Please try again, or visit goteamup.com.")));
}
