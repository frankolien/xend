/// Xend — embedded, non-custodial payments for mobile apps.
///
/// The entire public vocabulary. If a symbol isn't exported here, it's internal.
/// A consuming app should import *only* this file and never a crypto or RPC package.
/// If it needs to know what a blockhash is, the abstraction has leaked.
library xend_sdk;

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
        RateLimited,
        ChainRejected,
        NotImplementedYet;
