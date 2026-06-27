# Privacy-Preserving AI Bounty Judge

A commit-reveal implementation of the Ritual AI Bounty Judge, extended with Ritual-native hidden submission architecture.

---

## Problem

The original workshop version has a critical flaw: answers are public immediately after submission. This lets later participants read early answers, copy ideas, and submit improved versions — which is unfair in a winner-take-all bounty.

---

## Solution: Commit-Reveal Flow

Answers are hidden during the submission phase using a **commitment hash**. The real answer is only revealed after all commitments are locked in.

---

## Bounty Lifecycle

```
CREATE BOUNTY
    │
    │  Owner deploys bounty with:
    │  - question (public)
    │  - reward (ETH, locked in contract)
    │  - submissionDeadline
    │  - revealDeadline
    │
    ▼
[SUBMISSION PHASE]  → before submissionDeadline
    │
    │  Participants compute off-chain:
    │  commitment = keccak256(answer + salt + address + bountyId)
    │
    │  Call: submitCommitment(bountyId, commitment)
    │  ✓ Only the hash is stored on-chain — answer stays hidden
    │
    ▼
[REVEAL PHASE]  → after submissionDeadline, before revealDeadline
    │
    │  Participants call: revealAnswer(bountyId, answer, salt)
    │  Contract verifies: keccak256(answer, salt, sender, bountyId) == commitment
    │  ✓ Only matching reveals are accepted
    │  ✓ Unrevealed submissions are excluded from judging
    │
    ▼
[JUDGING PHASE]  → after revealDeadline
    │
    │  Owner calls: judgeAll(bountyId, llmInput)
    │  - llmInput contains ALL revealed answers for batch judging
    │  - Ritual AI evaluates submissions together (one LLM call)
    │  - AI returns ranking + winner recommendation
    │
    ▼
[FINALIZE]
    │
    │  Owner calls: finalizeWinner(bountyId, winnerIndex)
    │  - Human-in-the-loop: owner confirms the AI recommendation
    │  - Contract transfers ETH reward to winner
    │
    ▼
DONE ✓
```

---

## Key Rules

| Rule | Details |
|---|---|
| One commitment per participant | Cannot re-submit during submission phase |
| Commit before you reveal | Must have committed to be eligible for reveal |
| Hash must match | Invalid reveals are rejected |
| Reveal window enforced | Can only reveal between both deadlines |
| Batch judging | All answers sent in one AI request — no per-answer LLM calls |
| Human finalizes | AI recommends, owner finalizes payout |

---

## Commitment Formula

```solidity
bytes32 commitment = keccak256(
    abi.encodePacked(answer, salt, msg.sender, bountyId)
);
```

Including `msg.sender` and `bountyId` prevents:
- **Frontrunning**: another user cannot copy your commitment and reveal your answer as their own
- **Cross-bounty replay**: a commitment from bounty #1 is invalid for bounty #2

---

## Off-Chain Helper (JavaScript)

```javascript
const { ethers } = require("ethers");

function computeCommitment(answer, salt, participantAddress, bountyId) {
    return ethers.solidityPackedKeccak256(
        ["string", "bytes32", "address", "uint256"],
        [answer, salt, participantAddress, bountyId]
    );
}

// Example
const salt = ethers.randomBytes(32);
const commitment = computeCommitment(
    "My answer here",
    salt,
    "0xYourAddress",
    1  // bountyId
);
console.log("Commitment:", commitment);
console.log("Salt (save this!):", ethers.hexlify(salt));
```

---

## Functions

| Function | Who | When | Description |
|---|---|---|---|
| `createBounty()` | Owner | Anytime | Create bounty with reward + deadlines |
| `submitCommitment()` | Participant | Before submissionDeadline | Submit hash, hide answer |
| `revealAnswer()` | Participant | Between deadlines | Reveal answer + salt |
| `judgeAll()` | Owner | After revealDeadline | Trigger Ritual AI batch judging |
| `finalizeWinner()` | Owner | After judged | Pay winner |
| `getRevealedAnswers()` | Anyone | After reveal phase | Read all revealed answers |
| `computeCommitment()` | Anyone | Anytime | Helper to compute hash off-chain |

---

## Deployments

- **Network**: Any EVM chain (Ritual Testnet: Chain ID 1979)
- **Solidity**: 0.8.25
- **License**: MIT
