import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';
import 'package:async/async.dart'; // Only for Cipher*Stream
import 'package:pointycastle/export.dart'; // Only for Cipher*Stream

///  A stream whose content is generated by a function that runs in a separate
///  isolate.  A flow control protocol is established to throttle the
///  generating function, if needed, so that the Send/ReceivePort buffer
///  doesn't get overly large.
class IsolateStream<T, A> extends DelegatingStream<T> {
  /// Create a new stream with the given generating function, which
  /// takes an argument of type A, and produces an Iterator<T>.
  /// function should give an estimate of the size of an object of type T,
  /// in bytes; this is used to prevent buffer overflows.  maxBuf gives
  /// the maximum number of bytes of buffer to use in the Isolate port over
  /// which the data is sent; this defaults to a reasonable value.
  ///
  /// generator and sizeOf must be functions that can be passed to an Isolate.
  /// As of this writing, that means a top-level function or a static function.
  /// It is theoretically possible that future versions of Dart will loosen this
  /// restriction to include other functions that don't carry heap references.
  ///
  /// sizeOf is used to estimate the size of an object sent across the
  /// Send/Receive port pair, so that the buffer usage can be estimated
  /// against maxBuf.  You can use bytes, or any other unit of measurement
  /// for sizeOf and maxBuf, so long as you are consistent.
  IsolateStream(Iterator<T> Function(A) generator, A generatorArg,
      int Function(T value) sizeOf, {int maxBuf})
      : super(_IsolateStreamGenerator<T, A>(generatorArg, sizeOf, maxBuf)
            .generateFromIterator(generator));

  /// Create a new stream with the given generating function, which
  /// takes an argument of type A, and produces a StreamIterator<T>.
  /// Create a new stream with the given generating function.  The sizeOf
  /// function should give an estimate of the size of an object of type T,
  /// in bytes; this is used to prevent buffer overflows.  maxBuf gives
  /// the maximum number of bytes of buffer to use in the Isolate port over
  /// which the data is sent; this defaults to a reasonable value.
  ///
  /// generator and sizeOf must be functions that can be passed to an Isolate.
  /// As of this writing, that means a top-level function or a static function.
  /// It is theoretically possible that future versions of Dart will loosen this
  /// restriction to include other functions that don't carry heap references.
  ///
  /// sizeOf is used to estimate the size of an object sent across the
  /// Send/Receive port pair, so that the buffer usage can be estimated
  /// against maxBuf.  You can use bytes, or any other unit of measurement
  /// for sizeOf and maxBuf, so long as you are consistent.
  IsolateStream.fromStreamIterator(StreamIterator<T> Function(A) generator,
      A generatorArg, int Function(T value) sizeOf, {int maxBuf})
      : super(_IsolateStreamGenerator<T, A>(generatorArg, sizeOf, maxBuf)
            .generateFromStreamIterator(generator));

  /// Create a new stream with the given generating function, which
  /// takes an argument of type A and a Sink<T>.
  /// Create a new stream with the given generating function.  The sizeOf
  /// function should give an estimate of the size of an object of type T,
  /// in bytes; this is used to prevent buffer overflows.  maxBuf gives
  /// the maximum number of bytes of buffer to use in the Isolate port over
  /// which the data is sent; this defaults to a reasonable value.
  ///
  /// generator and sizeOf must be functions that can be passed to an Isolate.
  /// As of this writing, that means a top-level function or a static function.
  /// It is theoretically possible that future versions of Dart will loosen this
  /// restriction to include other functions that don't carry heap references.
  ///
  /// sizeOf is used to estimate the size of an object sent across the
  /// Send/Receive port pair, so that the buffer usage can be estimated
  /// against maxBuf.  You can use bytes, or any other unit of measurement
  /// for sizeOf and maxBuf, so long as you are consistent.
  ///
  /// The function is passed a sink that accepts any type, due to the way
  /// Dart's generics work.  The generating function shall only pass values
  /// of type T to the sink, or the results will be undefined (but will almost
  /// certainly be a type cast error).
  IsolateStream.fromSink(
      Future<void> Function(A, IsolateGeneratorSink<dynamic>) generator,
      A generatorArg,
      int Function(T value) sizeOf,
      {int maxBuf})
      : super(_IsolateStreamGenerator<T, A>(generatorArg, sizeOf, maxBuf)
            .generateFromSink(generator));
}

/// A helper to do the work of generating a Stream<T> in another isolate.
/// This is a separate class because we need to produce the Stream<T>
/// within the IsolateStream constructor.
class _IsolateStreamGenerator<T, A> {
  final A _generatorArg;
  final int Function(T value) _sizeOf;
  final int _ackEvery;
  final isolateExit = ReceivePort();
  final isolateResults = ReceivePort();
  final ackPortGetter = ReceivePort();

  _IsolateStreamGenerator(A _generatorArg, int Function(T) _sizeOf, int maxBuf)
      : this._raw(_generatorArg, _sizeOf,
            (maxBuf == null) ? 1 << 19 : max(1, maxBuf ~/ 2));

  _IsolateStreamGenerator._raw(
      this._generatorArg, this._sizeOf, this._ackEvery);

  _IsolateArgs _makeArgs(Function generator) => _IsolateArgs(
      generator,
      _generatorArg,
      isolateResults.sendPort,
      _ackEvery,
      ackPortGetter.sendPort,
      _sizeOf);

  Stream<T> generateFromIterator(Iterator<T> Function(A) generator) {
    return _generate(generator, _runIteratorInIsolate);
  }

  Stream<T> generateFromStreamIterator(
      StreamIterator<T> Function(A) generator) {
    return _generate(generator, _runStreamIteratorInIsolate);
  }

  Stream<T> generateFromSink(
          Future<void> Function(A, IsolateGeneratorSink<dynamic>) generator) =>
      _generate(generator, _runSinkInIsolate);

  Stream<T> _generate(Function generator, Function runner) async* {
    final args = _makeArgs(generator);
    final isolate = await Isolate.spawn<_IsolateArgs>(runner, args,
        onExit: isolateExit.sendPort,
        debugName: '${this.runtimeType}',
        errorsAreFatal: true);
    // Get the port that _runIsolate sends to us for flow control
    final SendPort ackPort = await ackPortGetter.first;
    ackPortGetter.close();
    final results = StreamIterator<dynamic>(isolateResults);
    while (await results.moveNext()) {
      final dynamic v = results.current;
      if (v == args.eof) {
        isolateResults.close();
      } else if (v == args.ack) {
        ackPort.send(args.ack); // We send an ack whenever one is asked for
      } else {
        assert(v != null);
        T tv = v as T;
        yield tv;
      }
    }
    isolate.kill();
    final done = await isolateExit.first;
    await isolateExit.close();
  }

  /// Initialize our run inside the isolate.
  static _SendPortAdapter _initializeRun(_IsolateArgs args) {
    // Give our creator a way to receive ack messages from us, so we can
    // do flow control.
    final ackPort = ReceivePort();
    args.ackPortPort.send(ackPort.sendPort);
    return _SendPortAdapter(args.port, args.eof, args.ack, args.ackEvery,
        StreamIterator(ackPort), args.sizeOf);
  }

  static void _runIteratorInIsolate(_IsolateArgs args) async {
    var dest = _initializeRun(args);
    Iterator generated = args.generator(args.generatorArg);
    while (generated.moveNext()) {
      dest.add(generated.current);
      await dest.waitForAcks(1);
    }
    dest.close();
    await dest.waitForAcks(0);
  }

  static void _runStreamIteratorInIsolate(_IsolateArgs args) async {
    var dest = _initializeRun(args);
    StreamIterator generated = args.generator(args.generatorArg);
    while (await generated.moveNext()) {
      dest.add(generated.current);
      await dest.waitForAcks(1);
    }
    dest.close();
    await dest.waitForAcks(0);
  }

  static void _runSinkInIsolate(_IsolateArgs args) async {
    var dest = _initializeRun(args);
    var sink = IsolateGeneratorSink<dynamic>._fromAdapter(dest);
    await args.generator(args.generatorArg, sink);
    assert(sink.closed); // The generator should close the sink
    sink.close(); //  ... in case it didn't
    await dest.waitForAcks(0);
  }
}

class IsolateGeneratorSink<T> implements Sink<T> {
  final _SendPortAdapter _dest;
  bool _closed = false;
  bool get closed => _closed;
  final IsolateGeneratorSink<dynamic> _delegatee; // can be  null

  IsolateGeneratorSink._fromAdapter(_SendPortAdapter dest)
      : this._raw(dest, null);

  /// Create a typed sink from a dynamic one.  This can be useful within
  /// a client's generator function.
  IsolateGeneratorSink.fromDynamic(IsolateGeneratorSink<dynamic> delegatee)
      : this._raw(delegatee._dest, delegatee);

  IsolateGeneratorSink._raw(this._dest, this._delegatee);

  @override
  void add(T data) {
    _dest.add(data); // Not type-safe, but this is a private API
  }

  /// If necessary, pause the sending isolate (the producer) until our
  /// consumer has processed sufficient data.  "await x.flushIfNeeded()"
  /// should be called regularly, in order
  /// to ensure the Send/Receive port buffer between the isolates doesn't
  /// get too big.
  Future<void> flushIfNeeded() async {
    return _dest.waitForAcks(1);
  }

  @override
  void close() {
    if (!_closed) {
      if (_delegatee != null) {
        _delegatee.close();
      } else {
        _dest.close();
      }
      _closed = true;
    }
  }
}

/// The args we send to the isolate.  Type information gets lost when
/// we send functions across the channel, but the public API is type-safe.
class _IsolateArgs {
  final Function generator;
  final dynamic generatorArg;
  final SendPort port;
  final int ackEvery;
  final SendPort ackPortPort; // The port over which we send the ack port
  final Function sizeOf;
  final ack = Capability();
  final eof = Capability();

  _IsolateArgs(this.generator, this.generatorArg, this.port, this.ackEvery,
      this.ackPortPort, this.sizeOf);
}

/// And adaptor to make our SendPort look like a Sink.  This coordinates
/// with the calling isolate to do flow control -- see waitForAcks
class _SendPortAdapter<T> implements Sink<T> {
  final SendPort _port;
  final Capability _eof;
  final Capability _ack;
  final int _ackEvery;
  final StreamIterator _ackPort;
  final Function _sizeOf;
  int _acksSent = 0;
  int _acksReceived = 0;
  int _bytesSent = 0; // Hooray for 64 bit ints!

  _SendPortAdapter(this._port, this._eof, this._ack, this._ackEvery,
      this._ackPort, this._sizeOf);

  @override
  void add(T data) {
    assert(data != null);
    _port.send(data);
    _bytesSent += _sizeOf(data);
    while (_acksSent < _bytesSent ~/ _ackEvery) {
      _port.send(_ack);
      _acksSent++;
    }
  }

  @override
  void close() {
    _port.send(_ack);
    _port.send(_eof);
    _acksSent++;
  }

  /// Wait until we've received all but pending of the acks we've sent.  By
  /// calling this with 1, we allow the Send/Receive port buffer to grow to
  /// 2x_ackEvery bytes before we stop the generator function.  We re-start
  /// it when we're down to 50% buffer occupancy.
  Future<void> waitForAcks(int pending) async {
    while (_acksReceived + pending < _acksSent) {
      final ok = await _ackPort.moveNext();
      assert(ok);
      assert(_ackPort.current == _ack);
      _acksReceived++;
    }
  }
}

/// As a convenience, here's the common case of an IsolateStream<Uint8List>.
/// This can be useful for generating a stream that is large -- many GB, or
/// even more -- that appears to come from a file or a socket.  Because it
/// runs in an isolate, the producer runs in parallel with the consumer.
/// IsolateStream does flow control, so that the buffer between producer
/// and consumer doesn't grow unreasonably large.  The maximum buffer
/// size is set by maxBuf; the default value of 1 MB should be reasonable
/// for most uses.
class Uint8ListIsolateStream<A> extends IsolateStream<Uint8List, A> {
  Uint8ListIsolateStream(
      Iterator<Uint8List> Function(A) generator, A generatorArg,
      {int maxBuf})
      : super(generator, generatorArg, _sizeOf, maxBuf: maxBuf);

  Uint8ListIsolateStream.fromStreamIterator(
      StreamIterator<Uint8List> Function(A) generator, A generatorArg,
      {int maxBuf})
      : super.fromStreamIterator(generator, generatorArg, _sizeOf,
            maxBuf: maxBuf);

  Uint8ListIsolateStream.fromSink(
      Future<void> Function(A, IsolateGeneratorSink) generator, A generatorArg,
      {int maxBuf})
      : super.fromSink(generator, generatorArg, _sizeOf, maxBuf: maxBuf);

  static int _sizeOfImpl(Uint8List el) => el.length;
  static var _sizeOf = _sizeOfImpl;
}
