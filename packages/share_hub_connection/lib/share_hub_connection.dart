library;

export 'src/identity.dart' show DeviceIdentity, ConnectionFailure;
export 'src/pairing.dart'
    show PairingHost, PairingAttempt, PairingOffer, offerLifetime;
export 'src/recovery.dart' show ConnectionRecoveryService;
export 'src/session.dart'
    show
        TrustedConnection,
        ConnectionPhase,
        SessionLease,
        ContinuousClock,
        connectionLifetime;
