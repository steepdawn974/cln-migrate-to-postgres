# Core Lightning Database Schema Documentation

## Overview

This document provides a comprehensive analysis of the Core Lightning SQLite database schema, including all tables, their relationships (both explicit and implicit), and an ERD diagram. This documentation reflects the current database state as migrated to PostgreSQL.

## Table Documentation

### Core System Tables

| Table | Purpose | Key Columns |
|-------|---------|-------------|
| `version` | Database version tracking | `version` |
| `vars` | Configuration variables | `name`, `val`, `intval`, `blobval` |
| `db_upgrades` | Upgrade history | `upgrade_from`, `lightning_version` |

### Node and Channel Management

| Table | Purpose | Key Columns | Relationships |
|-------|---------|-------------|---------------|
| `peers` | Lightning node peers | `id`, `node_id`, `address`, `feature_bits`, `last_known_address` | One-to-many with `channels` |
| `channels` | Payment channels | `id`, `peer_id`, `short_channel_id`, `scid`, `state` | FK: `peer_id` → `peers.id` |
| `channel_configs` | Channel configuration parameters | `id`, `dust_limit_satoshis`, `max_htlc_value_in_flight_msat`, `max_dust_htlc_exposure_msat` | Referenced by `channels.channel_config_local/remote` |
| `channel_funding_inflights` | In-flight channel funding attempts | `channel_id`, `funding_tx_id`, `funding_satoshi`, `lease_fee`, `splice_amnt` | FK: `channel_id` → `channels.id` |
| `channel_state_changes` | Channel state transition history | `channel_id`, `timestamp`, `old_state`, `new_state`, `message` | FK: `channel_id` → `channels.id` |
| `channel_blockheights` | Channel blockheight tracking per state | `channel_id`, `hstate`, `blockheight` | FK: `channel_id` → `channels.id` |
| `channel_feerates` | Channel feerate settings per state | `channel_id`, `hstate`, `feerate_per_kw` | FK: `channel_id` → `channels.id` |

### HTLC and Forwarding

| Table | Purpose | Key Columns | Relationships |
|-------|---------|-------------|---------------|
| `channel_htlcs` | HTLCs within channels | `id`, `channel_id`, `channel_htlc_id`, `payment_hash`, `groupid`, `updated_index` | FK: `channel_id` → `channels.id` |
| `forwards` | Forwarded payment events | `in_channel_scid`, `out_channel_scid`, `in_msatoshi`, `state`, `updated_index` | Implicit: via SCID to `channels.scid` |
| `forwarded_payments` | Legacy forwarding table (deprecated) | `in_htlc_id`, `out_htlc_id`, `in_msatoshi` | FK: `in/out_htlc_id` → `channel_htlcs.id` |

### Payments and Invoices

| Table | Purpose | Key Columns | Relationships |
|-------|---------|-------------|---------------|
| `payments` | Sent/received payments | `id`, `payment_hash`, `timestamp`, `status`, `destination`, `updated_index` | FK: `local_offer_id` → `offers.offer_id`, FK: `local_invreq_id` → `invoicerequests.invreq_id` |
| `invoices` | Payment requests | `id`, `payment_hash`, `state`, `msatoshi`, `label`, `updated_index` | FK: `local_offer_id` → `offers.offer_id` |
| `offers` | BOLT 12 offers | `offer_id`, `bolt12`, `label`, `status` | One-to-many with `invoices`, `payments` |
| `invoicerequests` | BOLT 12 invoice requests | `invreq_id`, `bolt12`, `label`, `status` | One-to-many with `payments` |

### Blockchain and UTXO Management

| Table | Purpose | Key Columns | Relationships |
|-------|---------|-------------|---------------|
| `blocks` | Blockchain block tracking | `height`, `hash`, `prev_hash` | Referenced by many tables via height |
| `transactions` | Bitcoin transactions | `id`, `blockheight`, `rawtx`, `type` | FK: `blockheight` → `blocks.height` |
| `outputs` | UTXO outputs | `prev_out_tx`, `prev_out_index`, `confirmation_height`, `spend_height`, `option_anchor_outputs` | FK: `confirmation_height/spend_height` → `blocks.height` |
| `utxoset` | Network UTXO set | `txid`, `outnum`, `blockheight`, `spend_height` | FK: `blockheight/spend_height` → `blocks.height` |
| `transaction_annotations` | Transaction metadata | `txid`, `idx`, `type`, `channel` | FK: `channel` → `channels.id` |

### Channel Transaction Tracking

| Table | Purpose | Key Columns | Relationships |
|-------|---------|-------------|---------------|
| `channeltxs` | Channel-related transactions | `id`, `channel_id`, `transaction_id`, `type` | FK: `channel_id` → `channels.id`, FK: `transaction_id` → `transactions.id` |

### Cryptographic and Security

| Table | Purpose | Key Columns | Relationships |
|-------|---------|-------------|---------------|
| `shachains` | SHA chain commitments | `id`, `min_index`, `num_valid` | One-to-many with `shachain_known` |
| `shachain_known` | Known SHA chain entries | `shachain_id`, `pos`, `idx`, `hash` | FK: `shachain_id` → `shachains.id` |
| `htlc_sigs` | HTLC signatures | `channelid`, `signature`, `inflight_tx_id`, `inflight_tx_outnum` | FK: `channelid` → `channels.id` |
| `penalty_bases` | Penalty transaction bases | `channel_id`, `commitnum`, `txid`, `amount` | FK: `channel_id` → `channels.id` |

### Storage and Misc

| Table | Purpose | Key Columns | Relationships |
|-------|---------|-------------|---------------|
| `datastore` | Generic key-value storage | `key`, `data`, `generation` | No relationships |
| `runes` | BOLT 12 runes management | `id`, `rune`, `last_used_nsec` | No relationships |
| `runes_blacklist` | Blacklisted rune indices | `start_index`, `end_index` | No relationships |
| `invoice_fallbacks` | Invoice fallback addresses | `scriptpubkey`, `invoice_id` | FK: `invoice_id` → `invoices.id` |
| `local_anchors` | Local anchor outputs | `channel_id`, `commitment_index`, `commitment_txid`, `commitment_weight` | FK: `channel_id` → `channels.id` |
| `addresses` | Address book | `keyidx`, `addrtype` | No relationships |
| `move_accounts` | Accounting move accounts | `id`, `name` | No relationships |
| `chain_moves` | Chain-based accounting moves | `id`, `account_channel_id`, `account_nonchannel_id`, `utxo`, `spending_txid` | FK: `account_channel_id` → `channels.id`, FK: `account_nonchannel_id` → `move_accounts.id` |
| `channel_moves` | Channel-based accounting moves | `id`, `account_channel_id`, `account_nonchannel_id`, `fees` | FK: `account_channel_id` → `channels.id`, FK: `account_nonchannel_id` → `move_accounts.id` |
| `network_events` | Network event tracking | `id`, `peer_id`, `type`, `timestamp`, `duration_nsec`, `connect_attempted` | No relationships |

## Detailed Table Schemas

### Core System Tables

#### version
```sql
CREATE TABLE version (version BIGINT)
```

#### vars
```sql
CREATE TABLE vars (
  name TEXT PRIMARY KEY,
  val TEXT,
  intval BIGINT,
  blobval BYTEA
);
```

#### db_upgrades
```sql
CREATE TABLE db_upgrades (upgrade_from BIGINT, lightning_version TEXT);
```

### Node and Channel Management

#### peers
```sql
CREATE TABLE peers (
  id BIGSERIAL PRIMARY KEY,
  node_id BYTEA UNIQUE,
  address TEXT,
  feature_bits BYTEA,
  last_known_address BYTEA
);
```

#### channels
```sql
CREATE TABLE channels (
  id BIGSERIAL PRIMARY KEY,
  peer_id BIGINT REFERENCES peers(id) ON DELETE CASCADE,
  short_channel_id TEXT,
  scid BIGINT,
  channel_config_local BIGINT,
  channel_config_remote BIGINT,
  state INTEGER,
  funder INTEGER,
  channel_flags INTEGER,
  minimum_depth INTEGER,
  next_index_local BIGINT,
  next_index_remote BIGINT,
  next_htlc_id BIGINT,
  funding_tx_id BYTEA,
  funding_tx_outnum INTEGER,
  funding_satoshi BIGINT,
  funding_locked_remote INTEGER,
  push_msatoshi BIGINT,
  msatoshi_local BIGINT,
  fundingkey_remote BYTEA,
  revocation_basepoint_remote BYTEA,
  payment_basepoint_remote BYTEA,
  htlc_basepoint_remote BYTEA,
  delayed_payment_basepoint_remote BYTEA,
  per_commit_remote BYTEA,
  old_per_commit_remote BYTEA,
  local_feerate_per_kw INTEGER,
  remote_feerate_per_kw INTEGER,
  shachain_remote_id BIGINT,
  shutdown_scriptpubkey_remote BYTEA,
  shutdown_keyidx_local BIGINT,
  last_sent_commit_state BIGINT,
  last_sent_commit_id INTEGER,
  last_tx BYTEA,
  last_sig BYTEA,
  closing_fee_received INTEGER,
  closing_sig_received BYTEA,
  first_blocknum BIGINT,
  last_was_revoke INTEGER,
  in_payments_offered BIGINT DEFAULT 0,
  in_payments_fulfilled BIGINT DEFAULT 0,
  in_msatoshi_offered BIGINT DEFAULT 0,
  in_msatoshi_fulfilled BIGINT DEFAULT 0,
  out_payments_offered BIGINT DEFAULT 0,
  out_payments_fulfilled BIGINT DEFAULT 0,
  out_msatoshi_offered BIGINT DEFAULT 0,
  out_msatoshi_fulfilled BIGINT DEFAULT 0,
  min_possible_feerate BIGINT,
  max_possible_feerate BIGINT,
  msatoshi_to_us_min BIGINT,
  msatoshi_to_us_max BIGINT,
  future_per_commitment_point BYTEA,
  last_sent_commit BYTEA,
  feerate_base INTEGER,
  feerate_ppm INTEGER,
  remote_upfront_shutdown_script BYTEA,
  remote_ann_node_sig BYTEA,
  remote_ann_bitcoin_sig BYTEA,
  option_static_remotekey INTEGER DEFAULT 0,
  shutdown_scriptpubkey_local BYTEA,
  our_funding_satoshi BIGINT DEFAULT 0,
  option_anchor_outputs INTEGER DEFAULT 0,
  full_channel_id BYTEA DEFAULT NULL,
  funding_psbt BYTEA DEFAULT NULL,
  closer INTEGER DEFAULT 2,
  state_change_reason INTEGER DEFAULT 0,
  funding_tx_remote_sigs_received INTEGER DEFAULT 0,
  revocation_basepoint_local BYTEA,
  payment_basepoint_local BYTEA,
  htlc_basepoint_local BYTEA,
  delayed_payment_basepoint_local BYTEA,
  funding_pubkey_local BYTEA,
  shutdown_wrong_txid BYTEA DEFAULT NULL,
  shutdown_wrong_outnum INTEGER DEFAULT NULL,
  local_static_remotekey_start BIGINT DEFAULT 0,
  remote_static_remotekey_start BIGINT DEFAULT 0,
  lease_commit_sig BYTEA DEFAULT NULL,
  lease_chan_max_msat BIGINT DEFAULT NULL,
  lease_chan_max_ppt INTEGER DEFAULT NULL,
  lease_expiry INTEGER DEFAULT 0,
  htlc_maximum_msat BIGINT DEFAULT 2100000000000000,
  htlc_minimum_msat BIGINT DEFAULT 0,
  alias_local BIGINT,
  alias_remote BIGINT,
  require_confirm_inputs_remote INTEGER DEFAULT 0,
  require_confirm_inputs_local INTEGER DEFAULT 0,
  channel_type BYTEA,
  ignore_fee_limits INTEGER DEFAULT 0,
  remote_feerate_base BIGINT,
  remote_feerate_ppm BIGINT,
  remote_cltv_expiry_delta BIGINT,
  remote_htlc_maximum_msat BIGINT,
  remote_htlc_minimum_msat BIGINT,
  last_stable_connection BIGINT DEFAULT 0,
  close_attempt_height BIGINT DEFAULT 0,
  old_scids BYTEA,
  withheld INTEGER DEFAULT 0
);
```

#### channel_configs
```sql
CREATE TABLE channel_configs (
  id BIGSERIAL PRIMARY KEY,
  dust_limit_satoshis BIGINT,
  max_htlc_value_in_flight_msat BIGINT,
  channel_reserve_satoshis BIGINT,
  htlc_minimum_msat BIGINT,
  to_self_delay INTEGER,
  max_accepted_htlcs INTEGER,
  max_dust_htlc_exposure_msat BIGINT DEFAULT 50000000
);
```

#### channel_funding_inflights
```sql
CREATE TABLE channel_funding_inflights (
  channel_id BIGSERIAL REFERENCES channels(id) ON DELETE CASCADE,
  funding_tx_id BYTEA,
  funding_tx_outnum INTEGER,
  funding_feerate INTEGER,
  funding_satoshi BIGINT,
  our_funding_satoshi BIGINT,
  funding_psbt BYTEA,
  last_tx BYTEA,
  last_sig BYTEA,
  funding_tx_remote_sigs_received INTEGER,
  lease_commit_sig BYTEA DEFAULT NULL,
  lease_chan_max_msat BIGINT DEFAULT NULL,
  lease_chan_max_ppt INTEGER DEFAULT NULL,
  lease_expiry INTEGER DEFAULT 0,
  lease_blockheight_start INTEGER DEFAULT 0,
  lease_fee BIGINT DEFAULT 0,
  lease_satoshi BIGINT,
  splice_amnt BIGINT DEFAULT 0,
  i_am_initiator INTEGER DEFAULT 0,
  force_sign_first INTEGER DEFAULT 0,
  remote_funding BYTEA,
  locked_scid BIGINT DEFAULT 0,
  i_sent_sigs INTEGER DEFAULT 0,
  PRIMARY KEY (channel_id, funding_tx_id)
);
```

#### channel_state_changes
```sql
CREATE TABLE channel_state_changes (
  channel_id BIGINT REFERENCES channels(id) ON DELETE CASCADE,
  timestamp BIGINT,
  old_state INTEGER,
  new_state INTEGER,
  cause INTEGER,
  message TEXT
);
```

#### channel_blockheights
```sql
CREATE TABLE channel_blockheights (
  channel_id BIGINT REFERENCES channels(id) ON DELETE CASCADE,
  hstate INTEGER,
  blockheight INTEGER,
  UNIQUE (channel_id, hstate)
);
```

#### channel_feerates
```sql
CREATE TABLE channel_feerates (
  channel_id BIGINT REFERENCES channels(id) ON DELETE CASCADE,
  hstate INTEGER,
  feerate_per_kw INTEGER,
  UNIQUE (channel_id, hstate)
);
```

### HTLC and Forwarding

#### channel_htlcs
```sql
CREATE TABLE channel_htlcs (
  id BIGSERIAL PRIMARY KEY,
  channel_id BIGINT REFERENCES channels(id) ON DELETE CASCADE,
  channel_htlc_id BIGINT,
  direction INTEGER,
  origin_htlc BIGINT,
  msatoshi BIGINT,
  cltv_expiry INTEGER,
  payment_hash BYTEA,
  payment_key BYTEA,
  routing_onion BYTEA,
  failuremsg BYTEA,
  malformed_onion INTEGER,
  hstate INTEGER,
  shared_secret BYTEA,
  received_time BIGINT,
  partid BIGINT,
  we_filled INTEGER,
  localfailmsg BYTEA,
  groupid BIGINT,
  min_commit_num BIGINT DEFAULT 0,
  max_commit_num BIGINT,
  fail_immediate INTEGER DEFAULT 0,
  fees_msat BIGINT DEFAULT 0,
  updated_index BIGINT DEFAULT 0,
  UNIQUE (channel_id, channel_htlc_id, direction)
);
```

#### forwards
```sql
CREATE TABLE forwards (
  in_channel_scid BIGINT,
  in_htlc_id BIGINT,
  out_channel_scid BIGINT,
  out_htlc_id BIGINT,
  in_msatoshi BIGINT,
  out_msatoshi BIGINT,
  state INTEGER,
  received_time BIGINT,
  resolved_time BIGINT,
  failcode INTEGER,
  forward_style INTEGER,
  updated_index BIGINT DEFAULT 0,
  PRIMARY KEY(in_channel_scid, in_htlc_id)
);
```

#### forwarded_payments (Deprecated)
```sql
CREATE TABLE forwarded_payments (
  in_htlc_id BIGINT REFERENCES channel_htlcs(id) ON DELETE SET NULL,
  out_htlc_id BIGINT REFERENCES channel_htlcs(id) ON DELETE SET NULL,
  in_channel_scid BIGINT,
  out_channel_scid BIGINT,
  in_msatoshi BIGINT,
  out_msatoshi BIGINT,
  state INTEGER,
  received_time BIGINT,
  resolved_time BIGINT,
  failcode INTEGER,
  forward_style INTEGER,
  UNIQUE(in_htlc_id, out_htlc_id)
);
```

### Payments and Invoices

#### payments
```sql
CREATE TABLE payments (
  id BIGSERIAL PRIMARY KEY,
  timestamp INTEGER,
  status INTEGER,
  payment_hash BYTEA,
  destination BYTEA,
  msatoshi BIGINT,
  payment_preimage BYTEA,
  path_secrets BYTEA,
  route_nodes BYTEA,
  route_channels BYTEA,
  failonionreply BYTEA,
  faildestperm INTEGER,
  failindex INTEGER,
  failcode INTEGER,
  failnode BYTEA,
  failchannel TEXT,
  failupdate BYTEA,
  msatoshi_sent BIGINT,
  faildetail TEXT,
  description TEXT,
  faildirection INTEGER,
  bolt11 TEXT,
  total_msat BIGINT,
  partid BIGINT,
  groupid BIGINT NOT NULL DEFAULT 0,
  local_offer_id BYTEA DEFAULT NULL REFERENCES offers(offer_id),
  paydescription TEXT,
  completed_at BIGINT,
  failscid BIGINT,
  local_invreq_id BYTEA DEFAULT NULL REFERENCES invoicerequests(invreq_id),
  updated_index BIGINT DEFAULT 0,
  UNIQUE (payment_hash, partid, groupid)
);
```

#### invoices
```sql
CREATE TABLE invoices (
  id BIGSERIAL PRIMARY KEY,
  state INTEGER,
  msatoshi BIGINT,
  payment_hash BYTEA,
  payment_key BYTEA,
  label TEXT,
  expiry_time BIGINT,
  pay_index BIGINT,
  msatoshi_received BIGINT,
  paid_timestamp BIGINT,
  bolt11 TEXT,
  description TEXT,
  features BYTEA DEFAULT '',
  local_offer_id BYTEA DEFAULT NULL REFERENCES offers(offer_id),
  updated_index BIGINT DEFAULT 0,
  paid_txid BYTEA,
  paid_outnum BIGINT,
  UNIQUE (label),
  UNIQUE (payment_hash),
  UNIQUE (pay_index)
);
```

#### offers
```sql
CREATE TABLE offers (
  offer_id BYTEA PRIMARY KEY,
  bolt12 TEXT,
  label TEXT,
  status INTEGER
);
```

#### invoicerequests
```sql
CREATE TABLE invoicerequests (
  invreq_id BYTEA PRIMARY KEY,
  bolt12 TEXT,
  label TEXT,
  status INTEGER
);
```

### Blockchain and UTXO Management

#### blocks
```sql
CREATE TABLE blocks (
  height INT,
  hash BYTEA,
  prev_hash BYTEA,
  UNIQUE(height)
);
```

#### transactions
```sql
CREATE TABLE transactions (
  id BYTEA,
  blockheight INTEGER REFERENCES blocks(height) ON DELETE SET NULL,
  txindex INTEGER,
  rawtx BYTEA,
  type BIGINT,
  channel_id BIGINT,
  PRIMARY KEY (id)
);
```

#### outputs
```sql
CREATE TABLE outputs (
  prev_out_tx BYTEA,
  prev_out_index INTEGER,
  value BIGINT,
  type INTEGER,
  status INTEGER,
  keyindex INTEGER,
  channel_id BIGINT,
  peer_id BYTEA,
  commitment_point BYTEA,
  scriptpubkey BYTEA,
  confirmation_height INTEGER REFERENCES blocks(height) ON DELETE SET NULL,
  spend_height INTEGER REFERENCES blocks(height) ON DELETE SET NULL,
  csv_lock INTEGER DEFAULT 1,
  is_in_coinbase INTEGER DEFAULT 0,
  reserved_til INTEGER DEFAULT NULL,
  option_anchor_outputs INTEGER DEFAULT 0,
  PRIMARY KEY (prev_out_tx, prev_out_index)
);
```

#### utxoset
```sql
CREATE TABLE utxoset (
  txid BYTEA,
  outnum INT,
  blockheight INT REFERENCES blocks(height) ON DELETE CASCADE,
  spendheight INT REFERENCES blocks(height) ON DELETE SET NULL,
  txindex INT,
  scriptpubkey BYTEA,
  satoshis BIGINT,
  PRIMARY KEY(txid, outnum)
);
```

#### transaction_annotations
```sql
CREATE TABLE transaction_annotations (
  txid BYTEA,
  idx INTEGER,
  location INTEGER,
  type INTEGER,
  channel BIGINT REFERENCES channels(id),
  UNIQUE(txid, idx)
);
```

### Channel Transaction Tracking

#### channeltxs
```sql
CREATE TABLE channeltxs (
  id BIGSERIAL PRIMARY KEY,
  channel_id BIGINT REFERENCES channels(id) ON DELETE CASCADE,
  type INTEGER,
  transaction_id BYTEA REFERENCES transactions(id) ON DELETE CASCADE,
  input_num INTEGER,
  blockheight INTEGER REFERENCES blocks(height) ON DELETE CASCADE
);
```

### Cryptographic and Security

#### shachains
```sql
CREATE TABLE shachains (
  id BIGSERIAL PRIMARY KEY,
  min_index BIGINT,
  num_valid BIGINT
);
```

#### shachain_known
```sql
CREATE TABLE shachain_known (
  shachain_id BIGINT REFERENCES shachains(id) ON DELETE CASCADE,
  pos INTEGER,
  idx BIGINT,
  hash BYTEA,
  PRIMARY KEY (shachain_id, pos)
);
```

#### htlc_sigs
```sql
CREATE TABLE htlc_sigs (
  channelid INTEGER REFERENCES channels(id) ON DELETE CASCADE,
  signature BYTEA,
  inflight_tx_id BYTEA,
  inflight_tx_outnum INTEGER
);
```

#### penalty_bases
```sql
CREATE TABLE penalty_bases (
  channel_id BIGINT REFERENCES channels(id) ON DELETE CASCADE,
  commitnum BIGINT,
  txid BYTEA,
  outnum INTEGER,
  amount BIGINT,
  PRIMARY KEY (channel_id, commitnum)
);
```

### Storage and Misc

#### datastore
```sql
CREATE TABLE datastore (
  key BYTEA PRIMARY KEY,
  data BYTEA,
  generation BIGINT
);
```

#### runes
```sql
CREATE TABLE runes (
  id BIGSERIAL PRIMARY KEY,
  rune TEXT,
  last_used_nsec BIGINT
);
```

#### runes_blacklist
```sql
CREATE TABLE runes_blacklist (
  start_index BIGINT,
  end_index BIGINT
);
```

#### invoice_fallbacks
```sql
CREATE TABLE invoice_fallbacks (
  scriptpubkey BYTEA PRIMARY KEY,
  invoice_id BIGINT REFERENCES invoices(id) ON DELETE CASCADE
);
```

#### local_anchors
```sql
CREATE TABLE local_anchors (
  channel_id BIGSERIAL REFERENCES channels(id),
  commitment_index BIGINT,
  commitment_txid BYTEA,
  commitment_anchor_outnum INTEGER,
  commitment_fee BIGINT,
  commitment_weight BIGINT,
  PRIMARY KEY (channel_id, commitment_index)
);
```

#### addresses
```sql
CREATE TABLE addresses (
  keyidx BIGINT,
  addrtype INTEGER
);
```

#### move_accounts
```sql
CREATE TABLE move_accounts (
  id BIGSERIAL PRIMARY KEY,
  name TEXT,
  UNIQUE (name)
);
```

#### chain_moves
```sql
CREATE TABLE chain_moves (
  id BIGSERIAL PRIMARY KEY,
  account_channel_id BIGINT REFERENCES channels(id),
  account_nonchannel_id BIGINT REFERENCES move_accounts(id),
  tag_bitmap BIGINT NOT NULL,
  credit_or_debit BIGINT NOT NULL,
  timestamp BIGINT NOT NULL,
  utxo BYTEA,
  spending_txid BYTEA,
  peer_id BYTEA,
  payment_hash BYTEA,
  block_height BIGINT,
  output_sat BIGINT,
  originating_channel_id BIGINT REFERENCES channels(id),
  originating_nonchannel_id BIGINT REFERENCES move_accounts(id),
  output_count BIGINT
);
```

#### channel_moves
```sql
CREATE TABLE channel_moves (
  id BIGSERIAL PRIMARY KEY,
  account_channel_id BIGINT REFERENCES channels(id),
  account_nonchannel_id BIGINT REFERENCES move_accounts(id),
  tag_bitmap BIGINT NOT NULL,
  credit_or_debit BIGINT NOT NULL,
  timestamp BIGINT NOT NULL,
  payment_hash BYTEA,
  payment_part_id BIGINT,
  payment_group_id BIGINT,
  fees BIGINT
);
```

#### network_events
```sql
CREATE TABLE network_events (
  id BIGSERIAL PRIMARY KEY,
  peer_id BYTEA NOT NULL,
  type INTEGER NOT NULL,
  timestamp BIGINT,
  reason TEXT,
  duration_nsec BIGINT,
  connect_attempted BIGINT
);
```

## Key Insights

### Architecture Patterns

1. **Channel-Centric Design**: Most entities revolve around channels as the central entity
2. **State Tracking**: Extensive state change tracking for channels and payments
3. **Dual Representation**: SCIDs stored as both TEXT and BIGINT for compatibility
4. **Temporal Data**: Rich timestamp support for time-based queries
5. **Cryptographic Storage**: Extensive blob storage for cryptographic data
6. **Performance Optimization**: Added `updated_index` columns for efficient querying
7. **Enhanced Features**: Support for splicing, dual funding, channel leases, and advanced fee management

### Migration Evolution

The schema shows clear evolution:
- Early versions focused on basic channel management
- Added HTLC tracking and payment routing
- Introduced BOLT 12 support (offers, invoicerequests)
- Enhanced fee management and channel features
- Added lease and channel upgrade support
- Recent additions: splicing, dual funding, enhanced accounting, performance optimizations

### Performance Considerations

- Heavy use of indexes on foreign key relationships
- Separate tables for different data access patterns
- Partitioning-like behavior through state-based tables
- Efficient SCID-based lookups for routing
- Added `updated_index` columns for incremental synchronization
- Enhanced accounting with detailed move tracking

### New Features in Current Schema

1. **Channel Splicing**: `splice_amnt` in `channel_funding_inflights`
2. **Dual Funding**: Multiple funding participants and signatures
3. **Channel Leases**: Lease-related columns across multiple tables
4. **Enhanced Accounting**: Detailed `chain_moves` and `channel_moves` with fee tracking
5. **Performance Indexes**: `updated_index` for incremental updates
6. **Network Event Tracking**: Detailed connection metrics
7. **Advanced Fee Management**: Remote fee parameters and limits
8. **Enhanced HTLC Management**: Grouping, fee tracking, and optimization flags

## Query Examples

### Forwarding Revenue Analysis
```sql
SELECT 
    date(f.received_time/1000000000, 'unixepoch') as date,
    SUM(f.in_msatoshi - f.out_msatoshi)/1000 as total_fee_sats,
    COUNT(*) as forward_count
FROM forwards f
WHERE f.state = 1  -- settled
GROUP BY date(f.received_time/1000000000, 'unixepoch')
ORDER BY date DESC;
```

### Channel Performance Metrics
```sql
SELECT 
    c.scid,
    p.node_id,
    COUNT(DISTINCT ch.id) as htlc_count,
    SUM(CASE WHEN ch.direction = 0 THEN ch.msatoshi ELSE 0 END) as inbound_msat,
    SUM(CASE WHEN ch.direction = 1 THEN ch.msatoshi ELSE 0 END) as outbound_msat
FROM channels c
JOIN peers p ON c.peer_id = p.id
LEFT JOIN channel_htlcs ch ON c.id = ch.channel_id
WHERE c.state = 2  -- CHANNELD_NORMAL
GROUP BY c.scid, p.node_id;
```

### Payment Success Rates
```sql
SELECT 
    status,
    COUNT(*) as count,
    SUM(msatoshi)/100000000 as total_btc
FROM payments
GROUP BY status;
```

### Recent Channel Activity
```sql
SELECT 
    c.scid,
    c.state,
    ch.updated_index,
    ch.received_time,
    ch.msatoshi,
    ch.payment_hash
FROM channels c
JOIN channel_htlcs ch ON c.id = ch.channel_id
WHERE ch.updated_index > EXTRACT(EPOCH FROM (NOW() - INTERVAL '1 hour')) * 1000000000
ORDER BY ch.updated_index DESC;
```

This documentation provides a comprehensive view of the current Core Lightning database structure, enabling complex queries and data analysis across all aspects of the Lightning Network node operation.
