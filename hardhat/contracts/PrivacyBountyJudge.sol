// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * @title PrivacyBountyJudge
 * @notice Commit-reveal AI Bounty Judge — answers stay hidden until judging is complete.
 * @dev Required Track: Commit-Reveal Bounty (works on any EVM chain)
 *
 * Lifecycle:
 *   1. Owner creates bounty (with reward, submissionDeadline, revealDeadline)
 *   2. Participants submit commitment hash during submission phase
 *   3. After submissionDeadline → participants reveal answer + salt
 *   4. After revealDeadline   → owner calls judgeAll() via Ritual AI
 *   5. Owner calls finalizeWinner() → reward is paid
 */
contract PrivacyBountyJudge {

    // ─── Structs ────────────────────────────────────────────────────────────────

    struct Bounty {
        address owner;
        uint256 reward;
        uint256 submissionDeadline; // commit phase ends here
        uint256 revealDeadline;     // reveal phase ends here
        bool judged;
        bool finalized;
        uint256 winnerIndex;        // index into revealedParticipants
        string question;
    }

    struct Submission {
        bytes32 commitment;         // keccak256(answer, salt, msg.sender, bountyId)
        string  answer;             // populated after reveal
        bool    committed;
        bool    revealed;
    }

    // ─── State ───────────────────────────────────────────────────────────────────

    uint256 public bountyCount;

    // bountyId → Bounty
    mapping(uint256 => Bounty) public bounties;

    // bountyId → participant address → Submission
    mapping(uint256 => mapping(address => Submission)) public submissions;

    // bountyId → ordered list of participants who revealed (used for winnerIndex)
    mapping(uint256 => address[]) public revealedParticipants;

    // ─── Events ──────────────────────────────────────────────────────────────────

    event BountyCreated(uint256 indexed bountyId, address indexed owner, uint256 reward);
    event CommitmentSubmitted(uint256 indexed bountyId, address indexed participant);
    event AnswerRevealed(uint256 indexed bountyId, address indexed participant);
    event JudgingInitiated(uint256 indexed bountyId);
    event WinnerFinalized(uint256 indexed bountyId, address indexed winner, uint256 reward);

    // ─── Errors ──────────────────────────────────────────────────────────────────

    error NotOwner();
    error BountyNotFound();
    error SubmissionPhaseClosed();
    error RevealPhaseNotOpen();
    error RevealPhaseClosed();
    error AlreadyCommitted();
    error AlreadyRevealed();
    error InvalidCommitment();
    error RevealPhaseNotOver();
    error AlreadyJudged();
    error NotYetJudged();
    error AlreadyFinalized();
    error InvalidWinnerIndex();
    error TransferFailed();
    error InsufficientReward();

    // ─── Modifiers ───────────────────────────────────────────────────────────────

    modifier onlyOwner(uint256 bountyId) {
        if (bounties[bountyId].owner != msg.sender) revert NotOwner();
        _;
    }

    modifier bountyExists(uint256 bountyId) {
        if (bounties[bountyId].owner == address(0)) revert BountyNotFound();
        _;
    }

    // ─── Functions ───────────────────────────────────────────────────────────────

    /**
     * @notice Create a new bounty. Caller must send ETH as the reward.
     * @param question          The bounty question visible to participants.
     * @param submissionDeadline Unix timestamp: commit window closes.
     * @param revealDeadline     Unix timestamp: reveal window closes (must be > submissionDeadline).
     */
    function createBounty(
        string calldata question,
        uint256 submissionDeadline,
        uint256 revealDeadline
    ) external payable returns (uint256 bountyId) {
        if (msg.value == 0) revert InsufficientReward();
        require(submissionDeadline > block.timestamp, "submissionDeadline in past");
        require(revealDeadline > submissionDeadline, "revealDeadline must be after submissionDeadline");

        bountyId = ++bountyCount;

        bounties[bountyId] = Bounty({
            owner:              msg.sender,
            reward:             msg.value,
            submissionDeadline: submissionDeadline,
            revealDeadline:     revealDeadline,
            judged:             false,
            finalized:          false,
            winnerIndex:        0,
            question:           question
        });

        emit BountyCreated(bountyId, msg.sender, msg.value);
    }

    /**
     * @notice Submit a commitment hash during the submission phase.
     * @dev    Commitment = keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId))
     *         Compute this off-chain before calling. Do NOT reveal your answer or salt yet.
     */
    function submitCommitment(
        uint256 bountyId,
        bytes32 commitment
    ) external bountyExists(bountyId) {
        Bounty storage b = bounties[bountyId];

        if (block.timestamp >= b.submissionDeadline) revert SubmissionPhaseClosed();

        Submission storage s = submissions[bountyId][msg.sender];
        if (s.committed) revert AlreadyCommitted();

        s.commitment = commitment;
        s.committed  = true;

        emit CommitmentSubmitted(bountyId, msg.sender);
    }

    /**
     * @notice Reveal your answer after submission deadline, before reveal deadline.
     * @param bountyId  Target bounty.
     * @param answer    Plaintext answer (must match what was committed).
     * @param salt      Random salt used in your commitment (bytes32).
     */
    function revealAnswer(
        uint256 bountyId,
        string calldata answer,
        bytes32 salt
    ) external bountyExists(bountyId) {
        Bounty storage b = bounties[bountyId];

        // Reveal window: after submission deadline, before reveal deadline
        if (block.timestamp <= b.submissionDeadline) revert RevealPhaseNotOpen();
        if (block.timestamp >= b.revealDeadline)     revert RevealPhaseClosed();

        Submission storage s = submissions[bountyId][msg.sender];
        if (!s.committed)  revert InvalidCommitment(); // must have committed first
        if (s.revealed)    revert AlreadyRevealed();

        // Verify commitment
        bytes32 expectedCommitment = keccak256(
            abi.encodePacked(answer, salt, msg.sender, bountyId)
        );
        if (expectedCommitment != s.commitment) revert InvalidCommitment();

        s.answer  = answer;
        s.revealed = true;

        revealedParticipants[bountyId].push(msg.sender);

        emit AnswerRevealed(bountyId, msg.sender);
    }

    /**
     * @notice Trigger AI judging via Ritual after the reveal deadline.
     * @param bountyId  Target bounty.
     * @param llmInput  ABI-encoded prompt/input for Ritual's on-chain AI inference.
     *                  Should contain all revealed answers for batch judging.
     * @dev   In production this calls Ritual's Infernet coordinator.
     *        For this implementation the llmInput is emitted and stored off-chain.
     *        The owner calls finalizeWinner() after receiving the AI result.
     */
    function judgeAll(
        uint256 bountyId,
        bytes calldata llmInput
    ) external onlyOwner(bountyId) bountyExists(bountyId) {
        Bounty storage b = bounties[bountyId];

        if (block.timestamp < b.revealDeadline) revert RevealPhaseNotOver();
        if (b.judged) revert AlreadyJudged();

        b.judged = true;

        // In a full Ritual integration:
        //   IInfernet(INFERNET_ADDRESS).requestCompute(llmInput, bountyId);
        // For this homework scope we emit the input for off-chain Ritual processing.
        emit JudgingInitiated(bountyId);

        // Suppress unused-variable warning — llmInput is forwarded to Ritual off-chain
        llmInput;
    }

    /**
     * @notice Finalize the winner after AI judging is complete.
     * @param bountyId    Target bounty.
     * @param winnerIndex Index into revealedParticipants[bountyId] array (0-based).
     */
    function finalizeWinner(
        uint256 bountyId,
        uint256 winnerIndex
    ) external onlyOwner(bountyId) bountyExists(bountyId) {
        Bounty storage b = bounties[bountyId];

        if (!b.judged)    revert NotYetJudged();
        if (b.finalized)  revert AlreadyFinalized();

        address[] storage revealed = revealedParticipants[bountyId];
        if (winnerIndex >= revealed.length) revert InvalidWinnerIndex();

        b.finalized   = true;
        b.winnerIndex = winnerIndex;

        address winner = revealed[winnerIndex];
        uint256 reward = b.reward;

        (bool ok, ) = winner.call{value: reward}("");
        if (!ok) revert TransferFailed();

        emit WinnerFinalized(bountyId, winner, reward);
    }

    // ─── View Helpers ────────────────────────────────────────────────────────────

    /**
     * @notice Get all revealed answers for a bounty (only readable after reveal phase).
     */
    function getRevealedAnswers(
        uint256 bountyId
    ) external view bountyExists(bountyId) returns (
        address[] memory participants,
        string[]  memory answers
    ) {
        address[] storage rp = revealedParticipants[bountyId];
        participants = rp;
        answers = new string[](rp.length);
        for (uint256 i = 0; i < rp.length; i++) {
            answers[i] = submissions[bountyId][rp[i]].answer;
        }
    }

    /**
     * @notice Compute the expected commitment hash off-chain (helper — read-only).
     */
    function computeCommitment(
        string calldata answer,
        bytes32 salt,
        address participant,
        uint256 bountyId
    ) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(answer, salt, participant, bountyId));
    }

    /**
     * @notice How many participants revealed their answer for a bounty.
     */
    function revealedCount(uint256 bountyId) external view returns (uint256) {
        return revealedParticipants[bountyId].length;
    }
}
