// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:async/async.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:term_glyph/term_glyph.dart' as glyph;

import 'package:test_api/src/backend/declarer.dart'; // ignore: implementation_imports
import 'package:test_api/src/backend/group.dart'; // ignore: implementation_imports
import 'package:test_api/src/backend/invoker.dart'; // ignore: implementation_imports
import 'package:test_api/src/backend/live_test.dart'; // ignore: implementation_imports
import 'package:test_api/src/backend/metadata.dart'; // ignore: implementation_imports
import 'package:test_api/src/backend/stack_trace_formatter.dart'; // ignore: implementation_imports
import 'package:test_api/src/backend/suite.dart'; // ignore: implementation_imports
import 'package:test_api/src/backend/suite_platform.dart'; // ignore: implementation_imports
import 'package:test_api/src/backend/test.dart'; // ignore: implementation_imports
import 'package:test_api/src/util/remote_exception.dart'; // ignore: implementation_imports

import 'suite_channel_manager.dart';

class RemoteListener {
  /// The test suite to run.
  final Suite _suite;

  /// The zone to forward prints to, or `null` if prints shouldn't be forwarded.
  final Zone _printZone;

  /// Extracts metadata about all the tests in the function returned by
  /// [getMain] and returns a channel that will send information about them.
  ///
  /// The main function is wrapped in a closure so that we can handle it being
  /// undefined here rather than in the generated code.
  ///
  /// Once that's done, this starts listening for commands about which tests to
  /// run.
  ///
  /// If [hidePrints] is `true` (the default), calls to `print()` within this
  /// suite will not be forwarded to the parent zone's print handler. However,
  /// the caller may want them to be forwarded in (for example) a browser
  /// context where they'll be visible in the development console.
  ///
  /// If [beforeLoad] is passed, it's called before the tests have been declared
  /// for this worker.
  static StreamChannel start(Function Function() getMain,
      {bool hidePrints = true, Future Function() beforeLoad}) {
    // This has to be synchronous to work around sdk#25745. Otherwise, there'll
    // be an asynchronous pause before a syntax error notification is sent,
    // which will cause the send to fail entirely.
    var controller =
        StreamChannelController<Object>(allowForeignErrors: false, sync: true);
    var channel = MultiChannel(controller.local);

    var verboseChain = true;

    var printZone = hidePrints ? null : Zone.current;
    var spec = ZoneSpecification(print: (_, __, ___, line) {
      if (printZone != null) printZone.print(line);
      channel.sink.add({'type': 'print', 'line': line});
    });

    SuiteChannelManager().asCurrent(() {
      StackTraceFormatter().asCurrent(() {
        runZoned(() async {
          dynamic main;
          try {
            main = getMain();
          } on NoSuchMethodError catch (_) {
            _sendLoadException(
                channel, 'No top-level main() function defined.');
            return;
          } catch (error, stackTrace) {
            _sendError(channel, error, stackTrace, verboseChain);
            return;
          }

          if (main is! Function) {
            _sendLoadException(
                channel, 'Top-level main getter is not a function.');
            return;
          } else if (main is! Function()) {
            _sendLoadException(
                channel, 'Top-level main() function takes arguments.');
            return;
          }

          var queue = StreamQueue(channel.stream);
          var message = await queue.next;
          assert(message['type'] == 'initial');

          queue.rest.listen((message) {
            if (message['type'] == 'close') {
              controller.local.sink.close();
              return;
            }

            assert(message['type'] == 'suiteChannel');
            SuiteChannelManager.current.connectIn(message['name'] as String,
                channel.virtualChannel(message['id'] as int));
          });

          if ((message['asciiGlyphs'] as bool) ?? false) glyph.ascii = true;
          var metadata = Metadata.deserialize(message['metadata']);
          verboseChain = metadata.verboseTrace;
          var declarer = Declarer(
              metadata: metadata,
              platformVariables:
                  Set.from(message['platformVariables'] as Iterable),
              collectTraces: message['collectTraces'] as bool,
              noRetry: message['noRetry'] as bool);

          StackTraceFormatter.current.configure(
              except: _deserializeSet(message['foldTraceExcept'] as List),
              only: _deserializeSet(message['foldTraceOnly'] as List));

          if (beforeLoad != null) await beforeLoad();

          Zone invokerGuardedZone;
          Invoker.guard(() {
            invokerGuardedZone = Zone.current;
          });
          await invokerGuardedZone.runUnary(
              declarer.declare, main as Function());

          var suite = Suite(
              declarer.build(), SuitePlatform.deserialize(message['platform']),
              path: message['path'] as String);

          runZoned(() {
            invokerGuardedZone
                .run(() => RemoteListener._(suite, printZone)._listen(channel));
          },
              // Make the declarer visible to running tests so that they'll throw
              // useful errors when calling `test()` and `group()` within a test,
              // and so they can add to the declarer's `tearDownAll()` list.
              zoneValues: {#test.declarer: declarer});
        }, onError: (error, StackTrace stackTrace) {
          _sendError(channel, error, stackTrace, verboseChain);
        }, zoneSpecification: spec);
      });
    });

    return controller.foreign;
  }

  /// Returns a [Set] from a JSON serialized list of strings.
  static Set<String> _deserializeSet(List list) {
    if (list == null) return null;
    if (list.isEmpty) return null;
    return Set.from(list);
  }

  /// Sends a message over [channel] indicating that the tests failed to load.
  ///
  /// [message] should describe the failure.
  static void _sendLoadException(StreamChannel channel, String message) {
    channel.sink.add({'type': 'loadException', 'message': message});
  }

  /// Sends a message over [channel] indicating an error from user code.
  static void _sendError(
      StreamChannel channel, error, StackTrace stackTrace, bool verboseChain) {
    channel.sink.add({
      'type': 'error',
      'error': RemoteException.serialize(
          error,
          StackTraceFormatter.current
              .formatStackTrace(stackTrace, verbose: verboseChain))
    });
  }

  RemoteListener._(this._suite, this._printZone);

  /// Send information about [_suite] across [channel] and start listening for
  /// commands to run the tests.
  void _listen(MultiChannel channel) {
    channel.sink.add({
      'type': 'success',
      'root': _serializeGroup(channel, _suite.group, [])
    });
  }

  /// Serializes [group] into a JSON-safe map.
  ///
  /// [parents] lists the groups that contain [group].
  Map _serializeGroup(
      MultiChannel channel, Group group, Iterable<Group> parents) {
    parents = parents.toList()..add(group);
    return {
      'type': 'group',
      'name': group.name,
      'metadata': group.metadata.serialize(),
      'trace': group.trace?.toString(),
      'setUpAll': _serializeTest(channel, group.setUpAll, parents),
      'tearDownAll': _serializeTest(channel, group.tearDownAll, parents),
      'entries': group.entries.map((entry) {
        return entry is Group
            ? _serializeGroup(channel, entry, parents)
            : _serializeTest(channel, entry as Test, parents);
      }).toList()
    };
  }

  /// Serializes [test] into a JSON-safe map.
  ///
  /// [groups] lists the groups that contain [test]. Returns `null` if [test]
  /// is `null`.
  Map _serializeTest(MultiChannel channel, Test test, Iterable<Group> groups) {
    if (test == null) return null;

    var testChannel = channel.virtualChannel();
    testChannel.stream.listen((message) {
      assert(message['command'] == 'run');
      _runLiveTest(test.load(_suite, groups: groups),
          channel.virtualChannel(message['channel'] as int));
    });

    return {
      'type': 'test',
      'name': test.name,
      'metadata': test.metadata.serialize(),
      'trace': test.trace?.toString(),
      'channel': testChannel.id
    };
  }

  /// Runs [liveTest] and sends the results across [channel].
  void _runLiveTest(LiveTest liveTest, MultiChannel channel) {
    channel.stream.listen((message) {
      assert(message['command'] == 'close');
      liveTest.close();
    });

    liveTest.onStateChange.listen((state) {
      channel.sink.add({
        'type': 'state-change',
        'status': state.status.name,
        'result': state.result.name
      });
    });

    liveTest.onError.listen((asyncError) {
      channel.sink.add({
        'type': 'error',
        'error': RemoteException.serialize(
            asyncError.error,
            StackTraceFormatter.current.formatStackTrace(asyncError.stackTrace,
                verbose: liveTest.test.metadata.verboseTrace))
      });
    });

    liveTest.onMessage.listen((message) {
      if (_printZone != null) _printZone.print(message.text);
      channel.sink.add({
        'type': 'message',
        'message-type': message.type.name,
        'text': message.text
      });
    });

    liveTest.run({#test.runner.test_channel: channel}).then(
        (_) => channel.sink.add({'type': 'complete'}));
  }
}
