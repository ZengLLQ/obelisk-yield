;; Title: Obelisk Yield Stripping & Stacking Vault Controller
;; Description: Non-custodial Bitcoin L2 Stacking Yield Stripping, Multi-Epoch Vault and Settlement Engine in Clarity

;; Error Codes
(define-constant ERR_NOT_AUTHORIZED (err u500))
(define-constant ERR_CONTRACT_PAUSED (err u501))
(define-constant ERR_EPOCH_EXPIRED (err u502))
(define-constant ERR_EPOCH_NOT_MATURED (err u503))
(define-constant ERR_EPOCH_NOT_FOUND (err u504))
(define-constant ERR_ZERO_AMOUNT (err u505))
(define-constant ERR_INSUFFICIENT_BALANCE (err u506))
(define-constant ERR_INVALID_MATURITY (err u507))
(define-constant ERR_NOTHING_TO_CLAIM (err u508))
(define-constant ERR_INSUFFICIENT_PRINCIPAL (err u509))

;; Math Constants
(define-constant PRECISION u1000000000000) ;; 10^12 Ray fixed-point scaling factor
(define-constant BPS_DIVISOR u10000) ;; 10,000 basis points = 100.00%

;; Protocol State
(define-data-var contract-owner principal tx-sender)
(define-data-var treasury-address principal tx-sender)
(define-data-var is-paused bool false)
(define-data-var protocol-fee-bps uint u200) ;; 2.00% protocol harvest fee
(define-data-var early-exit-fee-bps uint u50) ;; 0.50% early unwind fee
(define-data-var epoch-nonce uint u0)
(define-data-var total-stx-locked uint u0)
(define-data-var total-fees-collected uint u0)

;; Epoch Definition
(define-map epochs
  uint
  {
    start-block: uint,
    maturity-block: uint,
    total-principal-stx: uint,
    acc-yield-per-share: uint,
    total-yield-harvested: uint,
    total-yield-claimed: uint,
    is-finalized: bool,
  }
)

;; User Stake Position per Epoch
(define-map user-epoch-stakes
  {
    epoch-id: uint,
    user: principal,
  }
  {
    stx-deposited: uint,
    reward-debt: uint,
    claimed-yield: uint,
    redeemed-principal: uint,
  }
)

;; --- Administration ---

(define-public (set-contract-owner (new-owner principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR_NOT_AUTHORIZED)
    (var-set contract-owner new-owner)
    (ok true)
  )
)

(define-public (set-paused (paused bool))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR_NOT_AUTHORIZED)
    (var-set is-paused paused)
    (ok paused)
  )
)

(define-public (set-treasury (new-treasury principal))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR_NOT_AUTHORIZED)
    (var-set treasury-address new-treasury)
    (ok true)
  )
)

(define-public (set-protocol-fee (new-fee-bps uint))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR_NOT_AUTHORIZED)
    (asserts! (<= new-fee-bps u1000) ERR_NOT_AUTHORIZED) ;; Max 10%
    (var-set protocol-fee-bps new-fee-bps)
    (ok true)
  )
)

(define-public (set-early-exit-fee (new-fee-bps uint))
  (begin
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR_NOT_AUTHORIZED)
    (asserts! (<= new-fee-bps u500) ERR_NOT_AUTHORIZED) ;; Max 5%
    (var-set early-exit-fee-bps new-fee-bps)
    (ok true)
  )
)

;; --- Epoch Management ---

(define-public (create-epoch (maturity-block uint))
  (let ((new-id (+ (var-get epoch-nonce) u1)))
    (asserts! (is-eq tx-sender (var-get contract-owner)) ERR_NOT_AUTHORIZED)
    (asserts! (not (var-get is-paused)) ERR_CONTRACT_PAUSED)
    (asserts! (> maturity-block block-height) ERR_INVALID_MATURITY)

    (map-set epochs new-id {
      start-block: block-height,
      maturity-block: maturity-block,
      total-principal-stx: u0,
      acc-yield-per-share: u0,
      total-yield-harvested: u0,
      total-yield-claimed: u0,
      is-finalized: false,
    })

    (var-set epoch-nonce new-id)
    (ok new-id)
  )
)

;; --- Core Vault Operations ---

;; Deposit STX into an active epoch, minting equal Principal Tokens (PT) and Yield Tokens (YT)
(define-public (deposit-stx
    (epoch-id uint)
    (amount uint)
  )
  (let (
      (caller tx-sender)
      (vault-addr (as-contract tx-sender))
      (epoch (unwrap! (map-get? epochs epoch-id) ERR_EPOCH_NOT_FOUND))
      (existing-stake (default-to {
        stx-deposited: u0,
        reward-debt: u0,
        claimed-yield: u0,
        redeemed-principal: u0,
      }
        (map-get? user-epoch-stakes {
          epoch-id: epoch-id,
          user: caller,
        })
      ))
    )
    (asserts! (not (var-get is-paused)) ERR_CONTRACT_PAUSED)
    (asserts! (> amount u0) ERR_ZERO_AMOUNT)
    (asserts! (< block-height (get maturity-block epoch)) ERR_EPOCH_EXPIRED)

    ;; Transfer STX from user to vault
    (try! (stx-transfer? amount caller vault-addr))

    ;; Settle pending yield if user already has an existing stake
    (let (
        (acc-share (get acc-yield-per-share epoch))
        (old-deposited (get stx-deposited existing-stake))
        (old-debt (get reward-debt existing-stake))
        (pending (if (> old-deposited u0)
          (let ((gross (/ (* old-deposited acc-share) PRECISION)))
            (if (> gross old-debt)
              (- gross old-debt)
              u0
            )
          )
          u0
        ))
      )
      ;; Pay pending yield if any
      (if (> pending u0)
        (try! (as-contract (stx-transfer? pending tx-sender caller)))
        true
      )

      ;; Mint PT and YT to depositor
      (try! (contract-call? .principal-token mint caller amount))
      (try! (contract-call? .yield-token mint caller amount))

      ;; Update user position
      (let (
          (new-deposited (+ old-deposited amount))
          (new-debt (/ (* new-deposited acc-share) PRECISION))
          (new-claimed (+ (get claimed-yield existing-stake) pending))
        )
        (map-set user-epoch-stakes {
          epoch-id: epoch-id,
          user: caller,
        } {
          stx-deposited: new-deposited,
          reward-debt: new-debt,
          claimed-yield: new-claimed,
          redeemed-principal: (get redeemed-principal existing-stake),
        })

        ;; Update epoch state
        (map-set epochs epoch-id
          (merge epoch {
            total-principal-stx: (+ (get total-principal-stx epoch) amount),
            total-yield-claimed: (+ (get total-yield-claimed epoch) pending),
          })
        )

        (var-set total-stx-locked (+ (var-get total-stx-locked) amount))
        (ok true)
      )
    )
  )
)

;; Harvest yield rewards (from PoX Stacking or strategy) into the active epoch
(define-public (harvest-yield
    (epoch-id uint)
    (yield-amount uint)
  )
  (let (
      (caller tx-sender)
      (vault-addr (as-contract tx-sender))
      (epoch (unwrap! (map-get? epochs epoch-id) ERR_EPOCH_NOT_FOUND))
      (total-principal (get total-principal-stx epoch))
    )
    (asserts! (not (var-get is-paused)) ERR_CONTRACT_PAUSED)
    (asserts! (> yield-amount u0) ERR_ZERO_AMOUNT)
    (asserts! (> total-principal u0) ERR_INSUFFICIENT_PRINCIPAL)

    ;; Transfer yield STX into the vault
    (try! (stx-transfer? yield-amount caller vault-addr))

    ;; Calculate protocol fee
    (let (
        (fee-bps (var-get protocol-fee-bps))
        (fee (/ (* yield-amount fee-bps) BPS_DIVISOR))
        (net-yield (- yield-amount fee))
        (yield-per-share-delta (/ (* net-yield PRECISION) total-principal))
        (new-acc-share (+ (get acc-yield-per-share epoch) yield-per-share-delta))
      )
      ;; Send protocol fee to treasury
      (if (> fee u0)
        (try! (as-contract (stx-transfer? fee tx-sender (var-get treasury-address))))
        true
      )

      ;; Update epoch state
      (map-set epochs epoch-id
        (merge epoch {
          acc-yield-per-share: new-acc-share,
          total-yield-harvested: (+ (get total-yield-harvested epoch) net-yield),
        })
      )

      (var-set total-fees-collected (+ (var-get total-fees-collected) fee))
      (ok net-yield)
    )
  )
)

;; Claim accrued yield using held Yield Tokens
(define-public (claim-yield (epoch-id uint))
  (let (
      (caller tx-sender)
      (epoch (unwrap! (map-get? epochs epoch-id) ERR_EPOCH_NOT_FOUND))
      (stake (unwrap!
        (map-get? user-epoch-stakes {
          epoch-id: epoch-id,
          user: caller,
        })
        ERR_NOTHING_TO_CLAIM
      ))
      (yt-balance (unwrap! (contract-call? .yield-token get-balance caller)
        ERR_NOT_AUTHORIZED
      ))
      (acc-share (get acc-yield-per-share epoch))
      (effective-stake (if (> yt-balance (get stx-deposited stake))
        (get stx-deposited stake)
        yt-balance
      ))
      (gross-yield (/ (* effective-stake acc-share) PRECISION))
      (pending (if (> gross-yield (get reward-debt stake))
        (- gross-yield (get reward-debt stake))
        u0
      ))
    )
    (asserts! (not (var-get is-paused)) ERR_CONTRACT_PAUSED)
    (asserts! (> pending u0) ERR_NOTHING_TO_CLAIM)

    ;; Send pending yield to user
    (try! (as-contract (stx-transfer? pending tx-sender caller)))

    ;; Update user state
    (map-set user-epoch-stakes {
      epoch-id: epoch-id,
      user: caller,
    }
      (merge stake {
        reward-debt: gross-yield,
        claimed-yield: (+ (get claimed-yield stake) pending),
      })
    )

    ;; Update epoch state
    (map-set epochs epoch-id
      (merge epoch { total-yield-claimed: (+ (get total-yield-claimed epoch) pending) })
    )

    (ok pending)
  )
)

;; Redeem Principal after maturity (burns PT 1:1 for STX)
(define-public (redeem-principal
    (epoch-id uint)
    (pt-amount uint)
  )
  (let (
      (caller tx-sender)
      (epoch (unwrap! (map-get? epochs epoch-id) ERR_EPOCH_NOT_FOUND))
      (stake (unwrap!
        (map-get? user-epoch-stakes {
          epoch-id: epoch-id,
          user: caller,
        })
        ERR_NOTHING_TO_CLAIM
      ))
    )
    (asserts! (not (var-get is-paused)) ERR_CONTRACT_PAUSED)
    (asserts! (> pt-amount u0) ERR_ZERO_AMOUNT)
    (asserts! (>= block-height (get maturity-block epoch)) ERR_EPOCH_NOT_MATURED)

    ;; Burn PT from caller
    (try! (contract-call? .principal-token burn caller pt-amount))

    ;; Transfer STX 1:1 to user
    (try! (as-contract (stx-transfer? pt-amount tx-sender caller)))

    ;; Update user state
    (map-set user-epoch-stakes {
      epoch-id: epoch-id,
      user: caller,
    }
      (merge stake { redeemed-principal: (+ (get redeemed-principal stake) pt-amount) })
    )

    ;; Update epoch & protocol totals
    (map-set epochs epoch-id
      (merge epoch { total-principal-stx: (- (get total-principal-stx epoch) pt-amount) })
    )

    (var-set total-stx-locked (- (var-get total-stx-locked) pt-amount))
    (ok pt-amount)
  )
)

;; Early unwind: Burn equal PT and YT before maturity to exit position with small fee
(define-public (early-unwind
    (epoch-id uint)
    (amount uint)
  )
  (let (
      (caller tx-sender)
      (epoch (unwrap! (map-get? epochs epoch-id) ERR_EPOCH_NOT_FOUND))
      (stake (unwrap!
        (map-get? user-epoch-stakes {
          epoch-id: epoch-id,
          user: caller,
        })
        ERR_NOTHING_TO_CLAIM
      ))
    )
    (asserts! (not (var-get is-paused)) ERR_CONTRACT_PAUSED)
    (asserts! (> amount u0) ERR_ZERO_AMOUNT)
    (asserts! (< block-height (get maturity-block epoch)) ERR_EPOCH_EXPIRED)
    (asserts! (<= amount (get stx-deposited stake)) ERR_INSUFFICIENT_BALANCE)

    ;; Settle pending yield on unwound amount first
    (let (
        (acc-share (get acc-yield-per-share epoch))
        (gross (/ (* amount acc-share) PRECISION))
        (pending (if (> gross (get reward-debt stake))
          (- gross (get reward-debt stake))
          u0
        ))
        (fee (/ (* amount (var-get early-exit-fee-bps)) BPS_DIVISOR))
        (net-payout (- amount fee))
      )
      ;; Burn both PT and YT
      (try! (contract-call? .principal-token burn caller amount))
      (try! (contract-call? .yield-token burn caller amount))

      ;; Pay pending yield if any
      (if (> pending u0)
        (try! (as-contract (stx-transfer? pending tx-sender caller)))
        true
      )

      ;; Transfer fee to treasury and net-payout to user
      (if (> fee u0)
        (try! (as-contract (stx-transfer? fee tx-sender (var-get treasury-address))))
        true
      )
      (try! (as-contract (stx-transfer? net-payout tx-sender caller)))

      ;; Update user state
      (map-set user-epoch-stakes {
        epoch-id: epoch-id,
        user: caller,
      }
        (merge stake {
          stx-deposited: (- (get stx-deposited stake) amount),
          redeemed-principal: (+ (get redeemed-principal stake) net-payout),
        })
      )

      ;; Update epoch state
      (map-set epochs epoch-id
        (merge epoch { total-principal-stx: (- (get total-principal-stx epoch) amount) })
      )

      (var-set total-stx-locked (- (var-get total-stx-locked) amount))
      (var-set total-fees-collected (+ (var-get total-fees-collected) fee))
      (ok net-payout)
    )
  )
)

;; --- Read-Only Queries ---

(define-read-only (get-epoch (epoch-id uint))
  (map-get? epochs epoch-id)
)

(define-read-only (get-user-stake
    (epoch-id uint)
    (user principal)
  )
  (map-get? user-epoch-stakes {
    epoch-id: epoch-id,
    user: user,
  })
)

(define-read-only (get-pending-yield
    (epoch-id uint)
    (user principal)
  )
  (match (map-get? epochs epoch-id)
    epoch (match (map-get? user-epoch-stakes {
      epoch-id: epoch-id,
      user: user,
    })
      stake (let (
          (acc-share (get acc-yield-per-share epoch))
          (deposited (get stx-deposited stake))
          (gross (/ (* deposited acc-share) PRECISION))
          (debt (get reward-debt stake))
        )
        (ok (if (> gross debt)
          (- gross debt)
          u0
        ))
      )
      (ok u0)
    )
    ERR_EPOCH_NOT_FOUND
  )
)

(define-read-only (get-vault-summary)
  (ok {
    total-stx-locked: (var-get total-stx-locked),
    total-fees-collected: (var-get total-fees-collected),
    epoch-count: (var-get epoch-nonce),
    is-paused: (var-get is-paused),
    protocol-fee-bps: (var-get protocol-fee-bps),
    early-exit-fee-bps: (var-get early-exit-fee-bps),
  })
)
