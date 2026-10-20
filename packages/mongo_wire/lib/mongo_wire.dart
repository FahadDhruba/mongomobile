/// A small MongoDB client that speaks OP_MSG over TCP or TLS, plus a
/// lossless BSON codec and an Extended JSON reader and writer.
library;

export 'src/bson/codec.dart';
export 'src/bson/types.dart';
export 'src/cancel.dart';
export 'src/client.dart';
export 'src/ejson/ejson.dart';
export 'src/errors.dart';
export 'src/wire/connection_string.dart' show ConnectionString, HostAddress;
export 'src/wire/scram.dart'
    show ScramConversation, ScramMechanism, pbkdf2, saslPrep;
export 'src/wire/aws.dart';
export 'src/wire/oidc.dart';
export 'src/wire/srv.dart';
export 'src/wire/tunnel.dart';
export 'src/wire_client.dart';
