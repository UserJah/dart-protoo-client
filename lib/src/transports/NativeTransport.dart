import 'dart:convert';
import 'package:retry/retry.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../logger.dart';
import '../message.dart';
import 'TransportInterface.dart';

final _logger = Logger('Logger::NativeTransport');

class Transport extends TransportInterface {
  late bool _closed;
  late String _url;
  late dynamic _options;
  WebSocketChannel? _ws;

  Transport(String url, {dynamic options}) : super(url, options: options) {
    _logger.debug('constructor() [url:$url, options:$options]');
    this._closed = false;
    this._url = url;
    this._options = options ?? {};
    this._ws = null;

    this._runWebSocket();
  }

  bool wasConnected = false;
  int currentAttempt = 0;

  get closed => _closed;

  @override
  close() {
    if (_closed) {
      return;
    }

    _logger.debug('close()');

    _closed = true;
    safeEmit('close');

    try {
      _ws?.sink.close();
    } catch (error) {
      _logger.error('close() | error closing the WebSocket: $error');
    }
  }

  @override
  Future send(message) async {
    if (_closed) {
      throw new Exception('transport closed');
    }
    try {
      _ws?.sink.add(jsonEncode(message));
    } catch (error) {
      _logger.warn('send() failed:$error');
    }
  }

  _runWebSocket() async {
    _ws = IOWebSocketChannel.connect(Uri.parse(_url), protocols: ['protoo']);

    await _ws?.ready.then((value) {
      if (_closed) {
        return;
      }

      wasConnected = true;
      safeEmit('open');
    });

    _ws?.stream.listen(
      (event) {
        if (_closed) {
          return;
        }

        final message = Message.parse(event.data);

        if (message == null) {
          return;
        }

        if (listeners('message').length == 0) {
          logger.error('no listeners for WebSocket "message" event, ignoring received message');

          return;
        }

        safeEmit('message', message);
      },
      onDone: () {
        if (_closed) {
          return;
        }

        logger.warn(
            'WebSocket "close" event [wasClean:%s, code:%s, reason:"%s"], ${_ws?.closeCode}, ${_ws?.closeReason}');

        // Don't retry if code is 4000 (closed by the server).
        if (_ws?.closeCode != 4000) {
          if (!wasConnected) {
            safeEmit('failed', {'currentAttempt': currentAttempt});

            if (_closed) return;

            retry(
              () {
                currentAttempt++;
                if (currentAttempt == 8) {
                  currentAttempt = 0;
                }
                _runWebSocket();
              },
            );
          }
          // If it was connected, start from scratch.
          else {
            safeEmit('disconnected');

            if (_closed) return;

            _runWebSocket();

            return;
          }
          _closed = true;
          safeEmit('close');
        }
      },
      onError: (object, stackTrace) {
        if (_closed) {
          return;
        }

        logger.error('WebSocket "error" event ${object} ${stackTrace}');
      },
    );
  }
}
