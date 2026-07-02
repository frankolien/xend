/// Xend — embedded, non-custodial payments for mobile apps.
///
/// This library is the complete public surface of the SDK; any symbol not exported here
/// is internal and may change without notice. Applications import only this file and
/// need no blockchain or cryptography dependency of their own.
library xend;

export 'src/config.dart' show Xend, XendConfig;
export 'src/xend_wallet.dart' show XendWallet;
export 'src/models.dart'
    show Chain, Asset, Balance, TxHandle, TxStatus, TxCommitment, TxRecord;
export 'src/errors.dart'
    show
        XendError,
        NetworkError,
        InsufficientFunds,
        UserCancelledAuth,
        BlockhashExpired,
        InvalidRecipient,
        InvalidRecoveryPhrase,
        RateLimited,
        ChainRejected,
        NotImplementedYet;
