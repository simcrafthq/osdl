import Machine.Types
/-!
# Transfer types

The escrow transfer protocol's data types: the persistent transfer
identifier, the transfer status, the kernel's custody record, and the
component-facing send and receive vocabulary.
-/

namespace Machine

/-- A component-scoped transfer identifier returned by `send`. One
`TransferId` persists through the pending and blocked states of a transfer. -/
structure TransferId where
  value : UInt64
deriving Inhabited, BEq

/-- The current or terminal result of one entity transfer. -/
inductive TransferStatus where
  | pending
  | blocked
  | delivered
  | cancelled
deriving BEq, Inhabited

/-- The kernel's custody record for one entity transfer. While a transfer is
pending or blocked, the exact entity is held in kernel escrow and custody
remains with the sender. -/
structure TransferRecord where
  sender : Nat
  id : TransferId
  connectionIndex : Nat
  entity : Entity
  status : TransferStatus
deriving Inhabited

/-- The result of one earlier `send`, correlated by the persistent transfer
identifier. Carries no entity value. -/
inductive SendOutcome where
  | delivered
  | blocked
  | cancelled
deriving BEq, Inhabited

/-- The immediate decision for an entity arrival. `accept` moves the entity
atomically; `block` keeps the exact entity in kernel escrow with custody
remaining at the sender. -/
inductive ReceiveDecision where
  | accept
  | block
deriving BEq, Inhabited

end Machine
