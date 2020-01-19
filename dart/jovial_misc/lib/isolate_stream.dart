/// Support for running a generator function in a separate Isolate, with
/// flow control.
///
/// Sample usage, with FizzBuzz as a stand-in for a computationally intensive
/// series:
/// ```
/// import 'dart:async';
/// import 'package:convert/convert.dart';
/// import 'package:intl/intl.dart';
/// import 'package:jovial_misc/io_utils.dart';
/// import 'package:jovial_misc/isolate_stream.dart';
///
/// ///
/// /// Example of using [IsolateStream] to run a computationally-intensive
/// /// generator function in an isolate.  We use FizzBuzz as a
/// /// stand-in for a computationally intensive series of values.
/// ///
/// Future<void> isolate_stream_example() async {
///   const max = 25;
///   final fmt = NumberFormat();
///   const iterationPause = Duration(milliseconds: 250);
///   print('Generating FizzBuzz sequence up to ${fmt.format(max)}');
///
///   final stream = IsolateStream<String>(FizzBuzzGenerator(max));
///   // Our stream will be limited to 11 strings in the buffer at a time.
///   for (var iter = StreamIterator(stream); await iter.moveNext();) {
///     print(iter.current);
///     await Future<void>.delayed(iterationPause);
///   }
///   // Note that the producer doesn't run too far ahead of the consumer,
///   // because the buffer is limited to 30 strings.
/// }
///
/// /// The generator that runs in a separate isolate.
/// class FizzBuzzGenerator extends IsolateStreamGenerator<String> {
///   final int _max;
///
///   FizzBuzzGenerator(this._max) {
///     print('FizzBuzzGenerator constructor.  Note that this only runs once.');
///     // This demonstrats that when FizzBuzzGenerator is sent to the other
///     // isolate, the receiving isolate does not run the constructor.
///   }
///
///   @override
///   Future<void> generate() async {
///     for (var i = 1; i <= _max; i++) {
///       var result = '';
///       if (i % 3 == 0) {
///         result = 'Fizz';
///       }
///       if (i % 5 == 0) {
///         result += 'Buzz';
///       }
///       print('        Generator sending $i $result');
///       if (result == '') {
///         await sendValue(i.toString());
///       } else {
///         await sendValue(result);
///       }
///     }
///   }
///
///   @override
///   int sizeOf(String value) => 1;        // 1 entry
///
///   @override
///   int get bufferSize  => 7;            // Buffer up to 7 entries
/// }
///
/// ///
/// /// Run the examples
/// ///
/// void main() async {
///   await data_io_stream_example();
///   print('');
///   await isolate_stream_example();
/// }
/// ```

library isolate_stream;

import 'dart:async';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:async/async.dart';

///
///  A [Stream] whose content is generated by a function that runs in a
///  separate [Isolate].  A flow control protocol is established to
///  throttle the generating function, if needed, so that the
///  [SendPort]/[ReceivePort] buffer doesn't get overly large.
///
class IsolateStream<T> extends DelegatingStream<T> {
  final _ConsumerSession<T> _session;

  /// Initialize a new stream with the given generator.  A new isolate is
  /// created using [Isolate.spawn], and the generator is sent to that
  /// isolate over a [SendPort].  The generator must therefore obey the
  /// restrictions described for sending an object instance in the dart
  /// VM described in [SendPort.send].  The generator must be a subclass
  /// of IsolateStreamGenerator<T>; it cannot merely implement the interface.
  ///
  /// The generator sends objects of type T to our stream by calling
  /// appropriate inherited methods of [IsolateStreamGenerator].
  /// A flow control protocol is established to throttle the generator,
  /// so that the buffer between the two isolates doesn't grow without bound.
  IsolateStream(IsolateStreamGenerator generator)
      : this._fromSession(_ConsumerSession(generator));

  IsolateStream._fromSession(this._session) : super(_session.spawnAndRun());

  /// Request our generating funciton to shut down, by calling
  /// [Isolate.kill] with the given argument.  This should not
  /// normally be necessary, but it may be
  /// useful to clean up under exceptional circumstances.
  void kill({int priority = Isolate.beforeNextEvent}) =>
      _session.kill(priority);
}

///
/// An object that runs in another isolate to generate the values given
/// by an [IsolateStream].  Clients of [IsolateStream] subclass this.
/// An instance is provided to the [IsolateStream] constructor, and is
/// sent to a new isolate using [SendPort.send].  The new isolate is created
/// with [Isolate.spawn].  See the restrictions in [SendPort.send] about
/// sending object instances.
///
/// Note that this object is a Sink<T>, so it can be passed to function
/// that send data to a Sink.  If this is done, however, it is the
/// client's responsibility to see that [flushIfNeeded] is called on a
/// regular basis.
///
///  See also [IsolateByteStreamGenerator].
///
abstract class IsolateStreamGenerator<T> implements Sink<T> {
  _ProducerSession _session; // null in consumer

  /// Initialize a new generator.
  IsolateStreamGenerator();

  ///
  /// Generate the values for the [IsolateStream].  An implementation of
  /// this method can send values using the appropriate methods of
  /// this class.  When this method returns, the generating isolate is
  /// killed, and the [IsolateStream] is set as having received its
  /// last element.
  ///
  Future<void> generate();

  /// Give an estimate of the size of the given value.  This size should
  /// be in the same units [bufferSize].
  int sizeOf(T value);

  /// Give the desired size of the buffer between the producing isolate and
  /// the consuming isolate.  A flow control protocol will
  /// attempt to keep the buffer between half full and completely full,
  /// if production is faster than consumption.  A buffer size of zero
  /// will cause rendezvous semantics, where the producer pauses until the
  /// consumer has taken the value.  The units should be the same
  /// as [sizeOf].
  int get bufferSize;

  /// Send the given value to the consumer, pausing if the buffer is
  /// full.  This may only be called in the producer isolate.
  Future<void> sendValue(T value) async {
    _ensureInConsumer();
    final size = _session.bufferSize;
    if (size > 1) {
      await _session.waitForAcks(1);
    } else if (size == 1) {
      // must wait until buffer is empty
      await _session.waitForAcks(0);
    }
    _session.add(value);
    if (size <= 0) {
      // rendezvous semantics - wait until received
      await _session.waitForAcks(0);
    }
  }

  /// Synchronously send the given value to the consumer, without regard
  /// to respecting the maximum buffer size.  If this is
  /// called, the caller must ensure that [flushIfNeeded] is called
  /// frequently enough to prevent excessive buffer growth.
  @override
  void add(T value) {
    _ensureInConsumer();
    _session.add(value);
  }

  /// If necessary, pause the sending isolate (the producer) until our
  /// consumer has processed sufficient data.  `await x.flushIfNeeded()`
  /// should be called regularly, in order to ensure the Send/Receive
  /// port buffer between the isolates doesn't get too big.
  ///
  /// [sendValue] calls this method, so when it is used, there is no need
  /// to call it again.
  ///
  /// If this object is used as a sink, this method should be called regularly.
  /// A reasonable way to do this in a subclass method would be as follows:
  /// ```
  ///     final OjectThatAcceptsSink sinkUser = ...;
  ///     while (there is work to do) {
  ///         await flushIfNeeded();
  ///         sinkUser.sendSomeDataTo(this);
  ///             // sendSomeDataTo() may call this.add() multiple times
  ///     }
  /// ```
  /// NOTE:  In the special case of a buffer size of zero, the
  ///        `await flushIfNeeded()` call should be after
  ///        `generateSomeData()` to give rendezvous semantics,
  ///        that is, to pause the producer until the item has been
  ///        consumed.
  Future<void> flushIfNeeded() {
    _ensureInConsumer();
    if (_session.bufferSize > 1) {
      return _session.waitForAcks(1);
    } else {
      // For a buffer of 1, it must be empty before adding an element.
      // For a buffer of 0, it must be empty before letting the add complete.
      return _session.waitForAcks(0);
    }
  }

  @override
  void close() {
    // Do nothing, because _ProducerSession.close() shuts everything down
    // for us.
  }

  void _ensureInConsumer() {
    if (_session == null) {
      throw StateError('Attempt to call producer method in consumer.');
    }
  }
}

///
/// An [IsolateStreamGenerator] for building an [IsolateStream] of
/// bytes, represented by [Uint8List] instances.
/// This could be used e.g. to simulate a large amount of data coming
/// from a `File` or a `Socket`.  As a convenience, this class
/// implements [sizeOf] to count bytes, and [bufferSize] to give
/// a reasonably large buffer.
///
abstract class IsolateByteStreamGenerator
    extends IsolateStreamGenerator<Uint8List> {
  /// Give number of bytes this element represents.
  @override
  int sizeOf(Uint8List value) => value.length;

  /// Give a resonable default buffer size of 64K bytes.
  @override
  int get bufferSize => 64 * 1024;
}

class _IsolateArgs {
  final IsolateStreamGenerator generator;
  final SendPort consumer;
  final SendPort ackPortPort; // The port over which we send the ack port
  final ack = Capability();
  final eof = Capability();

  _IsolateArgs(this.generator, this.consumer, this.ackPortPort);
}

class _ConsumerSession<T> {
  final IsolateStreamGenerator generator;
  int killedWith;
  Isolate isolate;

  _ConsumerSession(this.generator);

  Stream<T> spawnAndRun() async* {
    final producer = ReceivePort();
    final ackPortGetter = ReceivePort();
    final args =
        _IsolateArgs(generator, producer.sendPort, ackPortGetter.sendPort);
    if (killedWith != null) {
      return;
    }
    final isolateExit = ReceivePort();
    isolate = await Isolate.spawn(runInIsolate, args,
        onExit: isolateExit.sendPort,
        debugName: '${generator}',
        errorsAreFatal: true);
    if (killedWith != null) {
      isolate.kill(priority: killedWith);
      return;
    }
    // Get the port that runIsolate sends to us for flow control
    final ackPort = await ackPortGetter.first as SendPort;
    ackPortGetter.close();
    final results = StreamIterator<dynamic>(producer);
    while (await results.moveNext()) {
      final dynamic v = results.current;
      if (v == args.eof) {
        ackPort.send(args.ack); // We send an ack to the eof
        break;
      } else if (v == args.ack) {
        ackPort.send(args.ack); // We send an ack whenever one is asked for
      } else {
        yield v as T;
      }
    }
    await isolateExit.first;
    isolateExit.close();
    producer.close();
  }

  /// See [IsolateStream.kill]
  void kill(int priority) {
    priority ??= Isolate.beforeNextEvent;
    killedWith = priority;
    // Record the priority in case isolate is null -- see spawnAndRun().
    if (isolate != null) {
      isolate.kill(priority: priority);
    }
  }

  ///  Called by spawn(), so this runs in the producer Isolate
  static void runInIsolate(_IsolateArgs args) async {
    // Give our creator a way to receive ack messages from us, so we can
    // do flow control.
    final ackPort = ReceivePort();
    args.ackPortPort.send(ackPort.sendPort);

    final session = _ProducerSession(args, ackPort);
    args.generator._session = session;
    await args.generator.generate();
    await session.close();
    Isolate.current.kill();
  }
}

class _ProducerSession {
  final IsolateStreamGenerator generator;
  final SendPort consumer;
  final Capability ack;
  final Capability eof;
  final StreamIterator<dynamic> ackPort;
  final int bufferSize;

  int acksOutstanding = 0; // Acks sent but not yet received
  int amountPending = 0; // Amount of data pending us sending an ack

  _ProducerSession(_IsolateArgs args, ReceivePort ackPort)
      : generator = args.generator,
        consumer = args.consumer,
        ack = args.ack,
        eof = args.eof,
        ackPort = StreamIterator<dynamic>(ackPort),
        bufferSize = args.generator.bufferSize;
  // We copy bufferSize once so that there's no danger from a client
  // changing its mind.

  Future<void> close() {
    consumer.send(eof);
    acksOutstanding++;
    return waitForAcks(0);
  }

  void add(dynamic data) {
    consumer.send(data);
    final size = max(1, generator.sizeOf(data));
    // Want a size of at least 1, because even if our payload
    // contains nothing of interest, there is some fixed
    // overhead.
    amountPending += size * 2;
    final amountPerAck = max(2, bufferSize);

    /// This is a little tricky...  We want two acks for every
    /// complete buffer.
    while (amountPending >= amountPerAck) {
      consumer.send(ack);
      acksOutstanding++;
      amountPending -= amountPerAck;
    }
  }

  /// Wait until we've received all but pending of the acks we've sent.  By
  /// calling this with 1, we allow the Send/Receive port buffer to grow to
  /// buffer before we stop the generator function.  We re-start
  /// it when we're down to 50% buffer occupancy.
  Future<void> waitForAcks(int pending) async {
    while (acksOutstanding > pending) {
      final ok = await ackPort.moveNext();
      assert(ok);
      assert(ackPort.current == ack);
      acksOutstanding--;
    }
  }
}
