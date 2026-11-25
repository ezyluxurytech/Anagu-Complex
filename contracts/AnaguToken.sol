// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title AnaguToken
 * @notice Standalone, zero-dependency ERC-20 utility, statutory filing fee, and
 *         Registrar-controlled escrow settlement token for the ANAGU Land
 *         Administration ecosystem (Remix IDE ready — no Hardhat or external imports).
 *
 * @dev Supports Polygon Amoy Testnet (Chain ID 80002), Polygon PoS, and Besu QBFT.
 *      Workflow:
 *      1. Citizens settle statutory filing fees via `payLandRegistrationFee(parcelId)`.
 *      2. Buyers lock purchase funds in escrow via `openPurchaseEscrow(parcelId, seller, amount)`.
 *      3. After verifying statutory consent and executing `AnaguLandTitleNFT.registryTransfer`,
 *         the Ministry Registrar releases funds via `releasePurchaseEscrow` (or refunds via
 *         `refundPurchaseEscrow`).
 *      4. Zero PII stored on-chain — parcel identifiers are stored as keccak256 hashes.
 */
contract AnaguToken {
    // -------------------------------------------------------------------------
    // ERC-20 Metadata & Constants
    // -------------------------------------------------------------------------

    string public constant name = "ANAGU Land Registry Token";
    string public constant symbol = "ANAGU";
    uint8 public constant decimals = 18;

    /// @notice Hard cap: 1,000,000,000 ANAGU (18 decimals).
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 10 ** 18;

    /// @notice Default testnet faucet claim amount: 1,000 ANAGU.
    uint256 public constant FAUCET_DRIP_AMOUNT = 1_000 * 10 ** 18;

    /// @notice Cooldown between faucet claims per wallet on testnets.
    uint256 public constant FAUCET_COOLDOWN = 1 hours;

    // -------------------------------------------------------------------------
    // Role-Based Access Control (Standalone)
    // -------------------------------------------------------------------------

    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant REGISTRAR_ROLE = keccak256("REGISTRAR_ROLE");

    mapping(bytes32 => mapping(address => bool)) private _roles;

    // -------------------------------------------------------------------------
    // Reentrancy Guard (Standalone)
    // -------------------------------------------------------------------------

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _reentrancyStatus = _NOT_ENTERED;

    // -------------------------------------------------------------------------
    // ERC-20 Storage
    // -------------------------------------------------------------------------

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    // -------------------------------------------------------------------------
    // Statutory Fee & Purchase Escrow Types & Storage
    // -------------------------------------------------------------------------

    enum EscrowStatus {
        None,
        Funded,
        Released,
        Refunded
    }

    struct RegistrationFeeReceipt {
        address payer;
        uint256 amount;
        uint64 paidAt;
        bool paid;
    }

    struct PurchaseEscrow {
        uint256 escrowId;
        bytes32 parcelIdHash;
        address buyer;
        address seller;
        uint256 amount;
        EscrowStatus status;
        uint64 createdAt;
        uint64 settledAt;
        bytes32 instrumentHash;
    }

    /// @notice Ministry Land Registry Treasury receiving statutory filing fees.
    address public treasury;

    /// @notice Statutory fee required to file a land registration application (in wei, 18 decimals).
    uint256 public registrationFee;

    /// @notice Testnet faucet toggle (enable on Polygon Amoy Testnet, disable on mainnet).
    bool public testnetFaucetEnabled;

    /// @notice Monotonic 1-based escrow counter.
    uint256 private _nextEscrowId;

    mapping(bytes32 => RegistrationFeeReceipt) private _registrationReceipts;
    mapping(uint256 => PurchaseEscrow) private _escrows;
    mapping(bytes32 => uint256[]) private _parcelEscrowIds;
    mapping(address => uint64) public lastFaucetClaimAt;

    // -------------------------------------------------------------------------
    // Custom Errors
    // -------------------------------------------------------------------------

    error UnauthorizedRole(address account, bytes32 role);
    error ReentrancyDetected();
    error ZeroAddress();
    error InvalidAmount();
    error InsufficientBalance(address account, uint256 available, uint256 required);
    error InsufficientAllowance(address spender, uint256 currentAllowance, uint256 required);
    error InvalidParcelId();
    error InvalidInstrumentHash();
    error CapExceeded(uint256 requestedSupply, uint256 maxSupply);
    error RegistrationFeeAlreadyPaid(bytes32 parcelIdHash);
    error BuyerCannotBeSeller(address account);
    error EscrowNotFound(uint256 escrowId);
    error EscrowNotFunded(uint256 escrowId, EscrowStatus currentStatus);
    error UnauthorizedEscrowRefund(address caller, uint256 escrowId);
    error TestnetFaucetDisabled();
    error FaucetCooldownActive(uint256 retryAfterTimestamp);

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);

    event TreasuryUpdated(address indexed previousTreasury, address indexed newTreasury);
    event RegistrationFeeUpdated(uint256 previousFee, uint256 newFee);
    event TestnetFaucetToggled(bool enabled);
    event TestnetFaucetClaimed(address indexed recipient, uint256 amount, uint64 timestamp);

    event LandRegistrationFeePaid(
        bytes32 indexed parcelIdHash,
        address indexed payer,
        address indexed treasury,
        uint256 amount,
        uint64 paidAt
    );

    event PurchaseEscrowOpened(
        uint256 indexed escrowId,
        bytes32 indexed parcelIdHash,
        address indexed buyer,
        address seller,
        uint256 amount,
        uint64 createdAt
    );

    event PurchaseEscrowReleased(
        uint256 indexed escrowId,
        bytes32 indexed parcelIdHash,
        address indexed seller,
        uint256 amount,
        bytes32 instrumentHash,
        address releasedBy,
        uint64 settledAt
    );

    event PurchaseEscrowRefunded(
        uint256 indexed escrowId,
        bytes32 indexed parcelIdHash,
        address indexed buyer,
        uint256 amount,
        address refundedBy,
        string reason,
        uint64 settledAt
    );

    // -------------------------------------------------------------------------
    // Modifiers
    // -------------------------------------------------------------------------

    modifier onlyRole(bytes32 role) {
        if (!_roles[role][msg.sender]) {
            revert UnauthorizedRole(msg.sender, role);
        }
        _;
    }

    modifier nonReentrant() {
        if (_reentrancyStatus == _ENTERED) {
            revert ReentrancyDetected();
        }
        _reentrancyStatus = _ENTERED;
        _;
        _reentrancyStatus = _NOT_ENTERED;
    }

    // -------------------------------------------------------------------------
    // Constructor (Remix-Friendly Whole Token Inputs)
    // -------------------------------------------------------------------------

    /**
     * @param initialAdmin            Receives DEFAULT_ADMIN_ROLE & MINTER_ROLE. Pass address(0) to use msg.sender.
     * @param initialRegistrar        Receives REGISTRAR_ROLE for escrow release/refund. Pass address(0) to use initialAdmin.
     * @param initialTreasury         Receives registration fees & initial supply. Pass address(0) to use initialAdmin.
     * @param initialSupplyTokens     Whole ANAGU tokens to mint to treasury (e.g. 10000000 for 10M ANAGU; 0 defaults to 10,000,000).
     * @param initialRegFeeTokens     Whole ANAGU tokens for registration fee (e.g. 50 for 50 ANAGU).
     * @param enableFaucet            Set true on Polygon Amoy Testnet, false on mainnet.
     */
    constructor(
        address initialAdmin,
        address initialRegistrar,
        address initialTreasury,
        uint256 initialSupplyTokens,
        uint256 initialRegFeeTokens,
        bool enableFaucet
    ) {
        address admin = initialAdmin == address(0) ? msg.sender : initialAdmin;
        address registrar = initialRegistrar == address(0) ? admin : initialRegistrar;
        address treasuryAddr = initialTreasury == address(0) ? admin : initialTreasury;

        uint256 supplyWhole = initialSupplyTokens == 0 ? 10_000_000 : initialSupplyTokens;
        if (supplyWhole > MAX_SUPPLY / 10 ** 18) {
            revert CapExceeded(supplyWhole, MAX_SUPPLY / 10 ** 18);
        }
        uint256 supplyWei = supplyWhole * 10 ** 18;

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MINTER_ROLE, admin);
        _grantRole(REGISTRAR_ROLE, registrar);

        treasury = treasuryAddr;
        registrationFee = initialRegFeeTokens * 10 ** 18;
        testnetFaucetEnabled = enableFaucet;

        if (supplyWei > 0) {
            _mint(treasuryAddr, supplyWei);
        }
    }

    // -------------------------------------------------------------------------
    // Access Control Functions
    // -------------------------------------------------------------------------

    function hasRole(bytes32 role, address account) public view returns (bool) {
        return _roles[role][account];
    }

    function grantRole(bytes32 role, address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (account == address(0)) revert ZeroAddress();
        _grantRole(role, account);
    }

    function revokeRole(bytes32 role, address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_roles[role][account]) {
            _roles[role][account] = false;
            emit RoleRevoked(role, account, msg.sender);
        }
    }

    function renounceRole(bytes32 role) external {
        if (_roles[role][msg.sender]) {
            _roles[role][msg.sender] = false;
            emit RoleRevoked(role, msg.sender, msg.sender);
        }
    }

    function _grantRole(bytes32 role, address account) internal {
        if (!_roles[role][account]) {
            _roles[role][account] = true;
            emit RoleGranted(role, account, msg.sender);
        }
    }

    // -------------------------------------------------------------------------
    // Standard ERC-20 Functions
    // -------------------------------------------------------------------------

    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    function allowance(address owner, address spender) public view returns (uint256) {
        return _allowances[owner][spender];
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        _approve(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        _spendAllowance(from, msg.sender, value);
        _transfer(from, to, value);
        return true;
    }

    function burn(uint256 value) external {
        _burn(msg.sender, value);
    }

    function burnFrom(address account, uint256 value) external {
        _spendAllowance(account, msg.sender, value);
        _burn(account, value);
    }

    // -------------------------------------------------------------------------
    // Token Minting & Governance Controls
    // -------------------------------------------------------------------------

    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert InvalidAmount();
        uint256 nextSupply = _totalSupply + amount;
        if (nextSupply > MAX_SUPPLY) {
            revert CapExceeded(nextSupply, MAX_SUPPLY);
        }
        _mint(to, amount);
    }

    function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTreasury == address(0)) revert ZeroAddress();
        address prev = treasury;
        treasury = newTreasury;
        emit TreasuryUpdated(prev, newTreasury);
    }

    function setRegistrationFee(uint256 newFeeWei) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 prev = registrationFee;
        registrationFee = newFeeWei;
        emit RegistrationFeeUpdated(prev, newFeeWei);
    }

    function setTestnetFaucetEnabled(bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        testnetFaucetEnabled = enabled;
        emit TestnetFaucetToggled(enabled);
    }

    /**
     * @notice Polygon Amoy Testnet faucet so citizens and buyers can claim test ANAGU
     *         tokens to test land registration fees and purchase escrow flows.
     */
    function claimTestnetFaucet() external nonReentrant {
        if (!testnetFaucetEnabled) revert TestnetFaucetDisabled();

        uint64 lastClaim = lastFaucetClaimAt[msg.sender];
        if (lastClaim != 0 && block.timestamp < uint256(lastClaim) + FAUCET_COOLDOWN) {
            revert FaucetCooldownActive(uint256(lastClaim) + FAUCET_COOLDOWN);
        }

        uint256 nextSupply = _totalSupply + FAUCET_DRIP_AMOUNT;
        if (nextSupply > MAX_SUPPLY) {
            revert CapExceeded(nextSupply, MAX_SUPPLY);
        }

        lastFaucetClaimAt[msg.sender] = uint64(block.timestamp);
        _mint(msg.sender, FAUCET_DRIP_AMOUNT);

        emit TestnetFaucetClaimed(msg.sender, FAUCET_DRIP_AMOUNT, uint64(block.timestamp));
    }

    // -------------------------------------------------------------------------
    // Step 1 Due Process: Statutory Land Registration Fee Payment
    // -------------------------------------------------------------------------

    function payLandRegistrationFee(
        string calldata parcelId
    ) external nonReentrant returns (bytes32 parcelIdHash) {
        if (bytes(parcelId).length == 0) revert InvalidParcelId();

        parcelIdHash = keccak256(abi.encodePacked(parcelId));
        if (_registrationReceipts[parcelIdHash].paid) {
            revert RegistrationFeeAlreadyPaid(parcelIdHash);
        }

        uint256 fee = registrationFee;
        if (fee > 0) {
            _transfer(msg.sender, treasury, fee);
        }

        uint64 nowTs = uint64(block.timestamp);
        _registrationReceipts[parcelIdHash] = RegistrationFeeReceipt({
            payer: msg.sender,
            amount: fee,
            paidAt: nowTs,
            paid: true
        });

        emit LandRegistrationFeePaid(parcelIdHash, msg.sender, treasury, fee, nowTs);
    }

    // -------------------------------------------------------------------------
    // Step 4 Due Process: Statutory Land Purchase Escrow
    // -------------------------------------------------------------------------

    function openPurchaseEscrow(
        string calldata parcelId,
        address seller,
        uint256 amount
    ) external nonReentrant returns (uint256 escrowId) {
        if (bytes(parcelId).length == 0) revert InvalidParcelId();
        if (seller == address(0)) revert ZeroAddress();
        if (seller == msg.sender) revert BuyerCannotBeSeller(msg.sender);
        if (amount == 0) revert InvalidAmount();

        bytes32 parcelIdHash = keccak256(abi.encodePacked(parcelId));
        escrowId = ++_nextEscrowId;
        uint64 nowTs = uint64(block.timestamp);

        _escrows[escrowId] = PurchaseEscrow({
            escrowId: escrowId,
            parcelIdHash: parcelIdHash,
            buyer: msg.sender,
            seller: seller,
            amount: amount,
            status: EscrowStatus.Funded,
            createdAt: nowTs,
            settledAt: 0,
            instrumentHash: bytes32(0)
        });
        _parcelEscrowIds[parcelIdHash].push(escrowId);

        _transfer(msg.sender, address(this), amount);

        emit PurchaseEscrowOpened(escrowId, parcelIdHash, msg.sender, seller, amount, nowTs);
    }

    function releasePurchaseEscrow(
        uint256 escrowId,
        bytes32 instrumentHash
    ) external onlyRole(REGISTRAR_ROLE) nonReentrant {
        if (instrumentHash == bytes32(0)) revert InvalidInstrumentHash();

        PurchaseEscrow storage escrow = _escrows[escrowId];
        if (escrow.escrowId == 0) revert EscrowNotFound(escrowId);
        if (escrow.status != EscrowStatus.Funded) {
            revert EscrowNotFunded(escrowId, escrow.status);
        }

        uint64 nowTs = uint64(block.timestamp);
        escrow.status = EscrowStatus.Released;
        escrow.settledAt = nowTs;
        escrow.instrumentHash = instrumentHash;

        _transfer(address(this), escrow.seller, escrow.amount);

        emit PurchaseEscrowReleased(
            escrowId,
            escrow.parcelIdHash,
            escrow.seller,
            escrow.amount,
            instrumentHash,
            msg.sender,
            nowTs
        );
    }

    function refundPurchaseEscrow(
        uint256 escrowId,
        string calldata reason
    ) external nonReentrant {
        PurchaseEscrow storage escrow = _escrows[escrowId];
        if (escrow.escrowId == 0) revert EscrowNotFound(escrowId);
        if (escrow.status != EscrowStatus.Funded) {
            revert EscrowNotFunded(escrowId, escrow.status);
        }
        if (msg.sender != escrow.buyer && !hasRole(REGISTRAR_ROLE, msg.sender)) {
            revert UnauthorizedEscrowRefund(msg.sender, escrowId);
        }

        uint64 nowTs = uint64(block.timestamp);
        escrow.status = EscrowStatus.Refunded;
        escrow.settledAt = nowTs;

        _transfer(address(this), escrow.buyer, escrow.amount);

        emit PurchaseEscrowRefunded(
            escrowId,
            escrow.parcelIdHash,
            escrow.buyer,
            escrow.amount,
            msg.sender,
            reason,
            nowTs
        );
    }

    // -------------------------------------------------------------------------
    // View Helpers
    // -------------------------------------------------------------------------

    function computeParcelIdHash(string calldata parcelId) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(parcelId));
    }

    function hasPaidRegistrationFee(string calldata parcelId) external view returns (bool) {
        return _registrationReceipts[keccak256(abi.encodePacked(parcelId))].paid;
    }

    function getRegistrationFeeReceipt(
        string calldata parcelId
    ) external view returns (RegistrationFeeReceipt memory) {
        return _registrationReceipts[keccak256(abi.encodePacked(parcelId))];
    }

    function getPurchaseEscrow(uint256 escrowId) external view returns (PurchaseEscrow memory) {
        if (_escrows[escrowId].escrowId == 0) revert EscrowNotFound(escrowId);
        return _escrows[escrowId];
    }

    function getParcelEscrowIds(string calldata parcelId) external view returns (uint256[] memory) {
        return _parcelEscrowIds[keccak256(abi.encodePacked(parcelId))];
    }

    function totalEscrows() external view returns (uint256) {
        return _nextEscrowId;
    }

    // -------------------------------------------------------------------------
    // Internal ERC-20 Accounting
    // -------------------------------------------------------------------------

    function _transfer(address from, address to, uint256 value) internal {
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        uint256 fromBalance = _balances[from];
        if (fromBalance < value) {
            revert InsufficientBalance(from, fromBalance, value);
        }
        unchecked {
            _balances[from] = fromBalance - value;
            _balances[to] += value;
        }
        emit Transfer(from, to, value);
    }

    function _mint(address to, uint256 value) internal {
        if (to == address(0)) revert ZeroAddress();
        _totalSupply += value;
        unchecked {
            _balances[to] += value;
        }
        emit Transfer(address(0), to, value);
    }

    function _burn(address from, uint256 value) internal {
        if (from == address(0)) revert ZeroAddress();
        uint256 fromBalance = _balances[from];
        if (fromBalance < value) {
            revert InsufficientBalance(from, fromBalance, value);
        }
        unchecked {
            _balances[from] = fromBalance - value;
            _totalSupply -= value;
        }
        emit Transfer(from, address(0), value);
    }

    function _approve(address owner, address spender, uint256 value) internal {
        if (owner == address(0) || spender == address(0)) revert ZeroAddress();
        _allowances[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    function _spendAllowance(address owner, address spender, uint256 value) internal {
        uint256 currentAllowance = _allowances[owner][spender];
        if (currentAllowance != type(uint256).max) {
            if (currentAllowance < value) {
                revert InsufficientAllowance(spender, currentAllowance, value);
            }
            unchecked {
                _allowances[owner][spender] = currentAllowance - value;
            }
        }
    }
}
