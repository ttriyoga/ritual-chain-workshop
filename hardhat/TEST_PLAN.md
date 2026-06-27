# Test Plan: PrivacyBountyJudge

Covers valid and invalid cases for the commit-reveal flow.

---

## Setup (Before Each Test)

```
- Deploy PrivacyBountyJudge
- owner = accounts[0]
- alice = accounts[1]
- bob   = accounts[2]
- carol = accounts[3]

- Create bounty:
    question           = "What is the best use case for Ritual?"
    submissionDeadline = now + 1 day
    revealDeadline     = now + 2 days
    reward             = 1 ETH
```

---

## Test Cases

---

### TC-01 — Happy Path: Full Valid Flow ✅

**Steps:**
1. Alice computes `commitment = keccak256("Alice answer", salt_a, alice, bountyId)`
2. Alice calls `submitCommitment(1, commitment)` → success
3. Bob computes `commitment = keccak256("Bob answer", salt_b, bob, bountyId)`
4. Bob calls `submitCommitment(1, commitment)` → success
5. Time advances past `submissionDeadline`
6. Alice calls `revealAnswer(1, "Alice answer", salt_a)` → success
7. Bob calls `revealAnswer(1, "Bob answer", salt_b)` → success
8. Time advances past `revealDeadline`
9. Owner calls `judgeAll(1, llmInput)` → success, `judged = true`
10. Owner calls `finalizeWinner(1, 0)` → success, Alice receives 1 ETH

**Expected:** All steps succeed, reward transferred to winner.

---

### TC-02 — Reveal with Wrong Answer ❌

**Steps:**
1. Alice commits `keccak256("Correct answer", salt_a, alice, 1)`
2. Time advances past `submissionDeadline`
3. Alice calls `revealAnswer(1, "Wrong answer", salt_a)`

**Expected:** Reverts with `InvalidCommitment()`

---

### TC-03 — Reveal with Wrong Salt ❌

**Steps:**
1. Alice commits `keccak256("Alice answer", salt_a, alice, 1)`
2. Time advances past `submissionDeadline`
3. Alice calls `revealAnswer(1, "Alice answer", wrong_salt)`

**Expected:** Reverts with `InvalidCommitment()`

---

### TC-04 — Submit Commitment After Deadline ❌

**Steps:**
1. Time advances past `submissionDeadline`
2. Alice calls `submitCommitment(1, someHash)`

**Expected:** Reverts with `SubmissionPhaseClosed()`

---

### TC-05 — Reveal Before Submission Deadline ❌

**Steps:**
1. Alice submits commitment
2. Alice immediately calls `revealAnswer()` (before `submissionDeadline`)

**Expected:** Reverts with `RevealPhaseNotOpen()`

---

### TC-06 — Reveal After Reveal Deadline ❌

**Steps:**
1. Alice submits commitment
2. Time advances past `submissionDeadline` AND past `revealDeadline`
3. Alice calls `revealAnswer()`

**Expected:** Reverts with `RevealPhaseClosed()`

---

### TC-07 — Double Commitment ❌

**Steps:**
1. Alice calls `submitCommitment(1, hash1)` → success
2. Alice calls `submitCommitment(1, hash2)` → attempt second commit

**Expected:** Reverts with `AlreadyCommitted()`

---

### TC-08 — Double Reveal ❌

**Steps:**
1. Alice commits and reveals successfully
2. Alice calls `revealAnswer()` again

**Expected:** Reverts with `AlreadyRevealed()`

---

### TC-09 — Frontrun Attack: Bob Copies Alice's Commitment ❌

**Steps:**
1. Alice submits `commitment = keccak256("Alice answer", salt_a, alice, 1)`
2. Bob copies Alice's commitment hash and calls `submitCommitment(1, alice_commitment)`
3. Time advances past `submissionDeadline`
4. Bob calls `revealAnswer(1, "Alice answer", salt_a)` — tries to reveal Alice's answer as his own

**Expected:** Reverts with `InvalidCommitment()`
**Why:** Bob's reveal computes `keccak256("Alice answer", salt_a, bob, 1)` ≠ alice's commitment (which used `alice` address).

---

### TC-10 — JudgeAll Before Reveal Deadline ❌

**Steps:**
1. Time advances past `submissionDeadline` but NOT past `revealDeadline`
2. Owner calls `judgeAll(1, llmInput)`

**Expected:** Reverts with `RevealPhaseNotOver()`

---

### TC-11 — Non-Owner Calls JudgeAll ❌

**Steps:**
1. Time advances past `revealDeadline`
2. Alice calls `judgeAll(1, llmInput)`

**Expected:** Reverts with `NotOwner()`

---

### TC-12 — FinalizeWinner Before Judging ❌

**Steps:**
1. Time advances past `revealDeadline`
2. Owner skips `judgeAll()` and calls `finalizeWinner(1, 0)` directly

**Expected:** Reverts with `NotYetJudged()`

---

### TC-13 — FinalizeWinner with Invalid Index ❌

**Steps:**
1. Only Alice revealed (1 participant, index 0 is valid)
2. Owner calls `finalizeWinner(1, 5)` — invalid index

**Expected:** Reverts with `InvalidWinnerIndex()`

---

### TC-14 — Double Finalize ❌

**Steps:**
1. Full happy path completes, winner finalized
2. Owner calls `finalizeWinner(1, 0)` again

**Expected:** Reverts with `AlreadyFinalized()`

---

### TC-15 — Unrevealed Submission Excluded from Judging ✅

**Steps:**
1. Alice and Bob both commit
2. Only Alice reveals
3. Owner calls `judgeAll(1, llmInput)` with only Alice's answer in input
4. `revealedParticipants[1]` has only Alice
5. Owner calls `finalizeWinner(1, 0)` — Alice wins

**Expected:** Bob's unrevealed submission is not in `revealedParticipants`, cannot be selected as winner.

---

### TC-16 — Zero Reward Bounty ❌

**Steps:**
1. Owner calls `createBounty(question, deadline1, deadline2)` with `msg.value = 0`

**Expected:** Reverts with `InsufficientReward()`

---

### TC-17 — Reveal Deadline Before Submission Deadline ❌

**Steps:**
1. Owner calls `createBounty(...)` with `revealDeadline < submissionDeadline`

**Expected:** Reverts with require message: `"revealDeadline must be after submissionDeadline"`

---

## Edge Cases Summary

| Scenario | Expected Result |
|---|---|
| Wrong answer in reveal | ❌ InvalidCommitment |
| Wrong salt in reveal | ❌ InvalidCommitment |
| Copied commitment from another user | ❌ InvalidCommitment (address mismatch) |
| Reveal too early | ❌ RevealPhaseNotOpen |
| Reveal too late | ❌ RevealPhaseClosed |
| Commit after deadline | ❌ SubmissionPhaseClosed |
| Judge before reveal deadline | ❌ RevealPhaseNotOver |
| Finalize without judging | ❌ NotYetJudged |
| Invalid winner index | ❌ InvalidWinnerIndex |
| Full valid flow | ✅ Reward transferred |
| Unrevealed submissions excluded | ✅ Not selectable as winner |
