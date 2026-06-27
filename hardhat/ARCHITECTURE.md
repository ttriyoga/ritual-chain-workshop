# Architecture Note: Commit-Reveal vs Ritual-Native Encrypted Submissions

---

## 1. Commit-Reveal Architecture (Required Track)

### How It Works

```
SUBMISSION PHASE
┌─────────────────────────────────────────────────────┐
│  Participant                                         │
│  ─────────                                           │
│  1. Chooses answer + random salt off-chain           │
│  2. Computes: commitment = keccak256(answer,         │
│               salt, address, bountyId)               │
│  3. Sends only the hash on-chain                     │
│                                                      │
│  On-chain state: [ hash ] ← no plaintext visible     │
└─────────────────────────────────────────────────────┘

REVEAL PHASE (after submission deadline)
┌─────────────────────────────────────────────────────┐
│  Participant sends: answer + salt                    │
│  Contract verifies hash matches commitment           │
│  On-chain state: [ hash, plaintext answer ]          │
│                                                      │
│  ⚠ Answers now public BEFORE AI judges them          │
└─────────────────────────────────────────────────────┘

JUDGING PHASE (after reveal deadline)
┌─────────────────────────────────────────────────────┐
│  Owner sends all revealed answers to Ritual AI       │
│  Ritual returns ranking + winner recommendation      │
│  Owner finalizes, contract pays winner               │
└─────────────────────────────────────────────────────┘
```

### Pros
- Works on any EVM chain — no special infrastructure needed
- Simple to audit and understand
- No off-chain dependencies

### Cons
- **Answers become public before AI judging** — a late participant could read all revealed answers, then decide whether to reveal their own or stay hidden (strategic non-reveal)
- Ordering information leaked: who revealed first is visible
- Salt must be kept safe off-chain by participant

---

## 2. Ritual-Native Hidden Submission Architecture (Advanced Track)

### Core Idea

Instead of the commit-reveal pattern, participants encrypt their answers for a Ritual TEE (Trusted Execution Environment). The plaintext never touches the public chain. Only the TEE can decrypt and pass answers to the LLM — invisible to everyone else, including the bounty owner, until judging is complete.

### Flow Diagram

```
SUBMISSION PHASE
┌──────────────────────────────────────────────────────────────────┐
│  Participant                                                      │
│  ─────────                                                        │
│  1. Encrypts answer using Ritual TEE's public key                 │
│     ciphertext = TEE_pubkey.encrypt(answer)                       │
│  2. Submits ciphertext on-chain                                   │
│                                                                   │
│  On-chain state: [ ciphertext ] ← unreadable by anyone           │
│  Plaintext exists: only inside TEE during judging                 │
└──────────────────────────────────────────────────────────────────┘

JUDGING PHASE (triggered by owner)
┌──────────────────────────────────────────────────────────────────┐
│  Ritual TEE Node                                                  │
│  ────────────────                                                 │
│  1. Reads all ciphertexts from contract                           │
│  2. Decrypts each answer inside the TEE                           │
│     (plaintext never leaves the TEE environment)                  │
│  3. Sends ALL decrypted answers to LLM in one batch request       │
│  4. LLM returns: { winnerIndex, ranking, summary }                │
│  5. TEE signs the result and publishes to chain                   │
│  6. Publishes revealed answer bundle to IPFS                      │
│  7. Stores hash of bundle on-chain for verification               │
│                                                                   │
│  On-chain state: [ winnerIndex, revealedAnswersHash ]             │
└──────────────────────────────────────────────────────────────────┘

POST-JUDGING REVEAL
┌──────────────────────────────────────────────────────────────────┐
│  After judging completes:                                         │
│  - revealedAnswersRef  → IPFS or storage link (public)           │
│  - revealedAnswersHash → stored on-chain for verification         │
│  Anyone can verify: hash(IPFS content) == on-chain hash          │
└──────────────────────────────────────────────────────────────────┘
```

### What Lives Where

| Data | Location | Who Can Read |
|---|---|---|
| Encrypted answer (ciphertext) | On-chain | Anyone (but unreadable) |
| Plaintext answer | Inside TEE only (during judging) | Nobody before judging |
| LLM judging result | On-chain (after judging) | Anyone |
| Full revealed answers | IPFS (after judging) | Anyone — verifiable by hash |
| Winner index | On-chain | Anyone |

### Example Final Output Shape

```json
{
    "winnerIndex": 2,
    "ranking": [
        { "index": 2, "score": 94, "reason": "Best satisfies the rubric." },
        { "index": 0, "score": 78, "reason": "Good approach, less detailed." },
        { "index": 1, "score": 65, "reason": "Partially addresses the question." }
    ],
    "revealedAnswersRef": "ipfs://Qm...",
    "revealedAnswersHash": "0xabc123...",
    "summary": "Submission 2 provided the most complete and well-reasoned answer."
}
```

### Pros
- **Answers stay hidden until after AI judging** — no strategic late-reveal advantage
- Batch judging: one LLM call for all submissions
- TEE attestation proves the judging was done honestly
- Human-in-the-loop: owner still finalizes, AI only recommends

### Cons
- Requires Ritual TEE infrastructure
- More complex to implement and audit
- Participants must trust Ritual's TEE key management
- Off-chain IPFS dependency for revealed answer bundle

---

## 3. Comparison Table

| Dimension | Commit-Reveal | Ritual-Native TEE |
|---|---|---|
| Chain dependency | Any EVM | Ritual network |
| Answer privacy | Hidden until reveal phase | Hidden until after judging |
| When answers go public | During reveal phase | After judging completes |
| Strategic late-reveal possible? | Yes | No |
| LLM call pattern | Batch (after reveal phase) | Batch (inside TEE) |
| Complexity | Low | High |
| Auditability | Easy | Requires TEE attestation |
| Infrastructure | Contract only | Contract + Ritual TEE + IPFS |

---

## 4. Reflection Question

**"What should be public, what should stay hidden, and what should be decided by AI versus by a human in a bounty system?"**

In a fair bounty system, the bounty question and its reward should always be public — participants need to know what they're competing for and what's at stake. The submission deadline and judging criteria should also be transparent so everyone plays by the same rules. However, the actual answers submitted by participants must stay hidden during the active submission phase, because public answers destroy the core fairness guarantee: they allow later participants to read earlier submissions, borrow ideas, and craft an improved version with the unfair advantage of seeing the competition's work first.

AI is best suited for the evaluation and ranking step, where it can process all revealed answers together in one batch, score them against a rubric consistently, and produce an objective ranking without human bias or favoritism. This is where Ritual's approach adds real value — batch judging inside a TEE means the AI evaluates everything fairly before anyone can game the reveal order. However, the final payout decision should always remain with a human. AI can misinterpret context, be gamed through prompt injection in the answers themselves, or make mistakes that have real financial consequences. The human-in-the-loop finalization step is a critical safeguard: the owner reviews the AI recommendation and explicitly confirms the winner before any funds move, which keeps accountability where it belongs — with a real person who can be held responsible.
