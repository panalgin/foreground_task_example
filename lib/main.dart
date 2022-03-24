import 'dart:async';
import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter_activity_recognition/flutter_activity_recognition.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences_android/shared_preferences_android.dart';
import 'package:workmanager/workmanager.dart';

const simplePeriodicTask = "simplePeriodicTask";

void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) {
    print(
        "Native called background task: $task"); //simpleTask will be emitted here.

    return Future.value(true);
  });
}

void startCallback() {
  // The setTaskHandler function must be called to handle the task in the background.
  FlutterForegroundTask.setTaskHandler(FirstTaskHandler());
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  /*Workmanager().initialize(
      callbackDispatcher, // The top level function, aka callbackDispatcher
      isInDebugMode:
          true // If enabled it will post a notification whenever the task is running. Handy for debugging tasks
      );

  Workmanager().registerPeriodicTask(
    "uniqueTaskName",
    simplePeriodicTask,
    frequency: const Duration(minutes: 15),
  );*/

  runApp(const ExampleApp());
}

// The callback function should always be a top-level function.

class FirstTaskHandler extends TaskHandler {
  StreamSubscription<Position>? _gpsSubscription;
  StreamSubscription<Activity>? _activitySubscription;

  FlutterActivityRecognition? _activityRecognition;
  ActivityType _activityType = ActivityType.UNKNOWN;
  ActivityConfidence _activityConfidence = ActivityConfidence.LOW;

  int _updateCount = 0;

  @override
  Future<void> onStart(DateTime timestamp, SendPort? sendPort) async {
    listenActivityRecognitionUpdates();
  }

  listenActivityRecognitionUpdates() {
    _activityRecognition = FlutterActivityRecognition.instance;

    if (_activityRecognition != null) {
      print("Start listening activity recognition updates.");

      _activitySubscription =
          _activityRecognition?.activityStream.listen((event) {
        if (event.type != ActivityType.UNKNOWN) {
          FlutterForegroundTask.updateService(
            notificationTitle: event.type.name,
            notificationText: event.confidence.name,
          );

          _activityType = event.type;
          _activityConfidence = event.confidence;
        }

        print("Activity: ${event.type.name} (${event.confidence.name})");
      });
    }
  }

  cleanListeners() async {
    print("Cleaning background listeners");

    await _activitySubscription?.cancel();
    await _gpsSubscription?.cancel();

    _activitySubscription = null;
    _gpsSubscription = null;

    _activityRecognition = null;
  }

  @override
  Future<void> onEvent(DateTime timestamp, SendPort? sendPort) async {
    print("Foreground tick at: ${DateTime.now()}");
    _updateCount++;

    if (_updateCount == 360) {
      print("Resetting service components");

      _updateCount = 0;

      await cleanListeners();
      await listenActivityRecognitionUpdates();

      return;
    }

    if (_activityType == ActivityType.STILL &&
        _activityConfidence == ActivityConfidence.HIGH) {
      if (_gpsSubscription != null) {
        await _gpsSubscription?.cancel();
        _gpsSubscription = null;
      }

      FlutterForegroundTask.updateService(
        notificationTitle: 'Gps Module',
        notificationText: 'Stopped',
      );
    } else if (_activityType != ActivityType.UNKNOWN) {
      _gpsSubscription ??= Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          distanceFilter: 5,
        ),
      ).listen((event) {
        // Update notification content.
        FlutterForegroundTask.updateService(
            notificationTitle: 'Current Position',
            notificationText: '${event.latitude}, ${event.longitude}');

        // Send data to the main isolate.
        // sendPort?.send(event);

        print("GpsEvent: ${event.latitude}, ${event.longitude}");
      });
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    // You can use the clearAllData function to clear all the stored data.
    await _gpsSubscription?.cancel();
    await _activitySubscription?.cancel();

    _gpsSubscription = null;
    _activitySubscription = null;
  }

  @override
  void onButtonPressed(String id) {
    // Called when the notification button on the Android platform is pressed.
    print('onButtonPressed >> $id');
  }
}

class ExampleApp extends StatefulWidget {
  const ExampleApp({Key? key}) : super(key: key);

  @override
  _ExampleAppState createState() => _ExampleAppState();
}

class _ExampleAppState extends State<ExampleApp> {
  ReceivePort? _receivePort;
  late FlutterActivityRecognition activityRecognition;

  Future<void> _initForegroundTask() async {
    await FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'notification_channel_id',
        channelName: 'Foreground Notification',
        channelDescription:
            'This notification appears when the foreground service is running.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        iconData: const NotificationIconData(
          resType: ResourceType.mipmap,
          resPrefix: ResourcePrefix.ic,
          name: 'launcher',
        ),
        buttons: [
          const NotificationButton(id: 'sendButton', text: 'Send'),
          const NotificationButton(id: 'testButton', text: 'Test'),
        ],
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: const ForegroundTaskOptions(
        interval: 5000,
        autoRunOnBoot: true,
        allowWifiLock: true,
      ),
      printDevLog: true,
    );
  }

  Future<bool> _startForegroundTask() async {
    ReceivePort? receivePort;
    if (await FlutterForegroundTask.isRunningService) {
      receivePort = await FlutterForegroundTask.restartService();
    } else {
      receivePort = await FlutterForegroundTask.startService(
        notificationTitle: 'Foreground Service is running',
        notificationText: 'Tap to return to the app',
        callback: startCallback,
      );
    }

    if (receivePort != null) {
      _receivePort = receivePort;
      _receivePort?.listen((message) async {
        if (message is DateTime) {
          print('receive timestamp: $message');
        } else if (message is int) {
          print('receive updateCount: $message');
        }
      });

      return true;
    }

    return false;
  }

  Future<bool> _stopForegroundTask() async {
    return await FlutterForegroundTask.stopService();
  }

  @override
  void initState() {
    super.initState();
    activityRecognition = FlutterActivityRecognition.instance;
    isPermissionGrants();

    _initForegroundTask();
  }

  @override
  void dispose() {
    _receivePort?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      // A widget that prevents the app from closing when the foreground service is running.
      // This widget must be declared above the [Scaffold] widget.
      home: WithForegroundTask(
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Flutter Foreground Task'),
            centerTitle: true,
          ),
          body: _buildContentView(),
        ),
      ),
    );
  }

  Widget _buildContentView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _buildTestButton('start', onPressed: _startForegroundTask),
          _buildTestButton('stop', onPressed: _stopForegroundTask),
        ],
      ),
    );
  }

  Widget _buildTestButton(String text, {VoidCallback? onPressed}) {
    return ElevatedButton(
      child: Text(text),
      onPressed: onPressed,
    );
  }

  Future<bool> isPermissionGrants() async {
    // Check if the user has granted permission. If not, request permission.
    PermissionRequestResult reqResult;
    reqResult = await activityRecognition.checkPermission();
    if (reqResult == PermissionRequestResult.PERMANENTLY_DENIED) {
      print('Permission is permanently denied.');
      return false;
    } else if (reqResult == PermissionRequestResult.DENIED) {
      reqResult = await activityRecognition.requestPermission();
      if (reqResult != PermissionRequestResult.GRANTED) {
        print('Permission is denied.');
        return false;
      }
    }

    return true;
  }
}
