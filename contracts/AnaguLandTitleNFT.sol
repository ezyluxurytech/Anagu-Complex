// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC721Receiver {
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external returns (bytes4);
}

/**
 * @title AnaguLandTitleNFT
 * @notice Standalone, zero-dependency ERC-721 Statutory Land Title Registry for
 *         the ANAGU Land Administration Platform (Remix IDE ready — no Hardhat
 *         or external imports).
 *
 * Core invariants:
 *  - 1 registered land parcel = 1 unique non-fungible title token (permanent 1:1 mapping).
 *  - Zero PII stored on-chain; off-chain documents, coordinates, and statutory records
 *    are anchored via cryptographic hashes and non-sensitive cadastral references.
 *  - Community/Oracle attestation (ORACLE_ROLE) is mandatory before title minting,
 *    but attestation alone never grants ownership or authorizes minting.
 *  - Title issuance (`mintTitle`) and legal transfers (`registryTransfer`) are restricted
 *    to `REGISTRAR_ROLE`; peer-to-peer wallet transfers and approvals are blocked.
 *  - Section 28 statutory revocation (`revokeTitle`) is restricted to `GOVERNOR_ROLE`;
 *    revoked titles remain on-chain (never burned), are permanently non-transferable,
 *    and their parcel IDs can never be re-minted.
 */
contract AnaguLandTitleNFT {
    // -------------------------------------------------------------------------
    // ERC-721 Metadata
    // -------------------------------------------------------------------------

    string public constant name = "ANAGU Land Title NFT";
    string public constant symbol = "ANAGU-TITLE";
    string private _baseTokenURI;

    // -------------------------------------------------------------------------
    // Roles (Least Privilege, Standalone)
    // -------------------------------------------------------------------------

    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 public constant REGISTRAR_ROLE = keccak256("REGISTRAR_ROLE");
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant GOVERNOR_ROLE = keccak256("GOVERNOR_ROLE");

    mapping(bytes32 => mapping(address => bool)) private _roles;

    // -------------------------------------------------------------------------
    // Reentrancy Guard (Standalone)
    // -------------------------------------------------------------------------

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    uint256 private _reentrancyStatus = _NOT_ENTERED;

    // -------------------------------------------------------------------------
    // Types
    // -------------------------------------------------------------------------

    enum TitleStatus {
        Active,
        Revoked
    }

    enum RevocationGround {
        OverridingPublicInterest,
        BreachOfStatutoryCondition
    }

    struct TitleIssuanceRecord {
        bytes32 parcelIdHash;
        string cadastralRef;
        bytes32 spatialHash;
        bytes32 documentHash;
        bytes32 oracleAttestationHash;
        uint64 issuedAt;
        address issuedBy;
        address initialOwner;
    }

    struct TitleState {
        TitleStatus status;
        uint32 transferCount;
        bytes32 lastInstrumentHash;
        uint64 lastTransferredAt;
    }

    struct OracleAttestationRecord {
        bytes32 attestationHash;
        uint64 attestedAt;
        address attestedBy;
        bool exists;
    }

    struct TransferRecord {
        address from;
        address to;
        bytes32 instrumentHash;
        uint64 transferredAt;
        address executedBy;
    }

    struct RevocationRecord {
        bool revoked;
        RevocationGround ground;
        string gazetteNumber;
        bytes32 reasonHash;
        uint64 revokedAt;
        address revokedBy;
        address ownerAtRevocation;
    }

    // -------------------------------------------------------------------------
    // Custom Errors
    // -------------------------------------------------------------------------

    error UnauthorizedRole(address account, bytes32 role);
    error ReentrancyDetected();
    error ZeroAddress();
    error InvalidRecipient(address recipient);
    error ERC721InvalidReceiver(address receiver);
    error InvalidParcelId();
    error InvalidCadastralRef();
    error InvalidSpatialHash();
    error InvalidDocumentHash();
    error InvalidAttestationHash();
    error InvalidInstrumentHash();
    error InvalidGazetteNumber();
    error InvalidReasonHash();
    error ParcelAlreadyRegistered(bytes32 parcelIdHash, uint256 existingTokenId);
    error RevokedParcelCannotBeReminted(bytes32 parcelIdHash, uint256 existingTokenId);
    error OracleAttestationRequired(bytes32 parcelIdHash);
    error TitleDoesNotExist(uint256 tokenId);
    error TitleAlreadyRevoked(uint256 tokenId);
    error PeerToPeerTransferBlocked(uint256 tokenId);
    error TransferToSameOwner(uint256 tokenId, address owner);

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);
    event BaseURIUpdated(string newBaseURI);

    event OracleAttested(
        bytes32 indexed parcelIdHash,
        bytes32 indexed attestationHash,
        address indexed attestedBy,
        uint64 attestedAt
    );

    event TitleMinted(
        uint256 indexed tokenId,
        bytes32 indexed parcelIdHash,
        address indexed recipient,
        string cadastralRef,
        bytes32 spatialHash,
        bytes32 documentHash,
        bytes32 oracleAttestationHash,
        uint64 issuedAt,
        address issuedBy
    );

    event RegistryTransferExecuted(
        uint256 indexed tokenId,
        bytes32 indexed parcelIdHash,
        address indexed from,
        address to,
        bytes32 instrumentHash,
        uint64 transferredAt,
        address executedBy
    );

    event TitleRevoked(
        uint256 indexed tokenId,
        bytes32 indexed parcelIdHash,
        RevocationGround indexed ground,
        string gazetteNumber,
        bytes32 reasonHash,
        address ownerAtRevocation,
        address revokedBy,
        uint64 revokedAt
    );

    // -------------------------------------------------------------------------
    // State Variables
    // -------------------------------------------------------------------------

    uint256 private _nextTokenId = 1;

    mapping(uint256 => address) private _owners;
    mapping(address => uint256) private _balances;

    mapping(bytes32 => uint256) private _parcelToTokenId;
    mapping(bytes32 => OracleAttestationRecord) private _oracleAttestations;
    mapping(uint256 => TitleIssuanceRecord) private _issuanceRecords;
    mapping(uint256 => TitleState) private _titleStates;
    mapping(uint256 => TransferRecord[]) private _transferHistory;
    mapping(uint256 => RevocationRecord) private _revocationRecords;

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
    // Constructor (Remix-Friendly)
    // -------------------------------------------------------------------------

    /**
     * @param initialAdmin     Receives DEFAULT_ADMIN_ROLE. Pass address(0) to default to msg.sender.
     * @param initialRegistrar Receives REGISTRAR_ROLE (pass address(0) to assign later via grantRole).
     * @param initialOracle    Receives ORACLE_ROLE (pass address(0) to assign later via grantRole).
     * @param initialGovernor  Receives GOVERNOR_ROLE (pass address(0) to assign later via grantRole).
     */
    constructor(
        address initialAdmin,
        address initialRegistrar,
        address initialOracle,
        address initialGovernor
    ) {
        address admin = initialAdmin == address(0) ? msg.sender : initialAdmin;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);

        if (initialRegistrar != address(0)) {
            _grantRole(REGISTRAR_ROLE, initialRegistrar);
        }
        if (initialOracle != address(0)) {
            _grantRole(ORACLE_ROLE, initialOracle);
        }
        if (initialGovernor != address(0)) {
            _grantRole(GOVERNOR_ROLE, initialGovernor);
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

    function setBaseURI(string calldata newBaseURI) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _baseTokenURI = newBaseURI;
        emit BaseURIUpdated(newBaseURI);
    }

    function _grantRole(bytes32 role, address account) internal {
        if (!_roles[role][account]) {
            _roles[role][account] = true;
            emit RoleGranted(role, account, msg.sender);
        }
    }

    // -------------------------------------------------------------------------
    // Standard ERC-721 Read & P2P-Locked Transfer Interface
    // -------------------------------------------------------------------------

    function balanceOf(address owner) external view returns (uint256) {
        if (owner == address(0)) revert ZeroAddress();
        return _balances[owner];
    }

    function ownerOf(uint256 tokenId) public view returns (address) {
        address owner = _owners[tokenId];
        if (owner == address(0)) revert TitleDoesNotExist(tokenId);
        return owner;
    }

    function tokenURI(uint256 tokenId) external view returns (string memory) {
        if (_owners[tokenId] == address(0)) revert TitleDoesNotExist(tokenId);
        if (bytes(_baseTokenURI).length == 0) return "";
        return string(abi.encodePacked(_baseTokenURI, _toString(tokenId)));
    }

    function getApproved(uint256 tokenId) external view returns (address) {
        if (_owners[tokenId] == address(0)) revert TitleDoesNotExist(tokenId);
        return address(0);
    }

    function isApprovedForAll(address, address) external pure returns (bool) {
        return false;
    }

    function approve(address, uint256 tokenId) external pure {
        revert PeerToPeerTransferBlocked(tokenId);
    }

    function setApprovalForAll(address, bool) external pure {
        revert PeerToPeerTransferBlocked(0);
    }

    function transferFrom(address, address, uint256 tokenId) external pure {
        revert PeerToPeerTransferBlocked(tokenId);
    }

    function safeTransferFrom(address, address, uint256 tokenId) external pure {
        revert PeerToPeerTransferBlocked(tokenId);
    }

    function safeTransferFrom(address, address, uint256 tokenId, bytes calldata) external pure {
        revert PeerToPeerTransferBlocked(tokenId);
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return
            interfaceId == 0x01ffc9a5 || // ERC-165
            interfaceId == 0x80ac58cd || // ERC-721
            interfaceId == 0x5b5e139f;   // ERC-721 Metadata
    }

    // -------------------------------------------------------------------------
    // Statutory Land Registry State-Changing Functions
    // -------------------------------------------------------------------------

    /**
     * @notice Records a Community / Verification Oracle attestation prior to minting.
     */
    function recordOracleAttestation(
        string calldata parcelId,
        bytes32 attestationHash
    ) external onlyRole(ORACLE_ROLE) {
        bytes32 parcelIdHash = computeParcelIdHash(parcelId);
        if (attestationHash == bytes32(0)) revert InvalidAttestationHash();

        uint256 existingTokenId = _parcelToTokenId[parcelIdHash];
        if (existingTokenId != 0) {
            if (_titleStates[existingTokenId].status == TitleStatus.Revoked) {
                revert RevokedParcelCannotBeReminted(parcelIdHash, existingTokenId);
            }
            revert ParcelAlreadyRegistered(parcelIdHash, existingTokenId);
        }

        uint64 attestedAt = uint64(block.timestamp);
        _oracleAttestations[parcelIdHash] = OracleAttestationRecord({
            attestationHash: attestationHash,
            attestedAt: attestedAt,
            attestedBy: msg.sender,
            exists: true
        });

        emit OracleAttested(parcelIdHash, attestationHash, msg.sender, attestedAt);
    }

    /**
     * @notice Mints a unique ERC-721 Land Title NFT for an oracle-attested parcel.
     */
    function mintTitle(
        address to,
        string calldata parcelId,
        string calldata cadastralRef,
        bytes32 spatialHash,
        bytes32 documentHash
    ) external onlyRole(REGISTRAR_ROLE) nonReentrant returns (uint256 tokenId) {
        if (to == address(0)) revert InvalidRecipient(to);
        bytes32 parcelIdHash = computeParcelIdHash(parcelId);
        if (bytes(cadastralRef).length == 0) revert InvalidCadastralRef();
        if (spatialHash == bytes32(0)) revert InvalidSpatialHash();
        if (documentHash == bytes32(0)) revert InvalidDocumentHash();

        uint256 existingTokenId = _parcelToTokenId[parcelIdHash];
        if (existingTokenId != 0) {
            if (_titleStates[existingTokenId].status == TitleStatus.Revoked) {
                revert RevokedParcelCannotBeReminted(parcelIdHash, existingTokenId);
            }
            revert ParcelAlreadyRegistered(parcelIdHash, existingTokenId);
        }

        OracleAttestationRecord storage attestation = _oracleAttestations[parcelIdHash];
        if (!attestation.exists) {
            revert OracleAttestationRequired(parcelIdHash);
        }

        tokenId = _nextTokenId;
        unchecked {
            _nextTokenId = tokenId + 1;
        }

        uint64 issuedAt = uint64(block.timestamp);

        _parcelToTokenId[parcelIdHash] = tokenId;
        _owners[tokenId] = to;
        unchecked {
            _balances[to] += 1;
        }

        _issuanceRecords[tokenId] = TitleIssuanceRecord({
            parcelIdHash: parcelIdHash,
            cadastralRef: cadastralRef,
            spatialHash: spatialHash,
            documentHash: documentHash,
            oracleAttestationHash: attestation.attestationHash,
            issuedAt: issuedAt,
            issuedBy: msg.sender,
            initialOwner: to
        });

        _titleStates[tokenId] = TitleState({
            status: TitleStatus.Active,
            transferCount: 0,
            lastInstrumentHash: bytes32(0),
            lastTransferredAt: 0
        });

        emit Transfer(address(0), to, tokenId);
        emit TitleMinted(
            tokenId,
            parcelIdHash,
            to,
            cadastralRef,
            spatialHash,
            documentHash,
            attestation.attestationHash,
            issuedAt,
            msg.sender
        );

        _checkOnERC721Received(msg.sender, address(0), to, tokenId, "");
    }

    /**
     * @notice Executes an authorized Registrar-controlled transfer of an active land title.
     */
    function registryTransfer(
        uint256 tokenId,
        address to,
        bytes32 instrumentHash
    ) external onlyRole(REGISTRAR_ROLE) nonReentrant {
        address from = _owners[tokenId];
        if (from == address(0)) revert TitleDoesNotExist(tokenId);
        if (_titleStates[tokenId].status == TitleStatus.Revoked) revert TitleAlreadyRevoked(tokenId);
        if (to == address(0)) revert InvalidRecipient(to);
        if (to == from) revert TransferToSameOwner(tokenId, to);
        if (instrumentHash == bytes32(0)) revert InvalidInstrumentHash();

        uint64 transferredAt = uint64(block.timestamp);
        TitleState storage state = _titleStates[tokenId];
        state.transferCount += 1;
        state.lastInstrumentHash = instrumentHash;
        state.lastTransferredAt = transferredAt;

        _transferHistory[tokenId].push(
            TransferRecord({
                from: from,
                to: to,
                instrumentHash: instrumentHash,
                transferredAt: transferredAt,
                executedBy: msg.sender
            })
        );

        unchecked {
            _balances[from] -= 1;
            _balances[to] += 1;
        }
        _owners[tokenId] = to;

        emit Transfer(from, to, tokenId);
        emit RegistryTransferExecuted(
            tokenId,
            _issuanceRecords[tokenId].parcelIdHash,
            from,
            to,
            instrumentHash,
            transferredAt,
            msg.sender
        );

        _checkOnERC721Received(msg.sender, from, to, tokenId, "");
    }

    /**
     * @notice Records a Section 28 statutory revocation on-chain without burning the title.
     */
    function revokeTitle(
        uint256 tokenId,
        RevocationGround ground,
        string calldata gazetteNumber,
        bytes32 reasonHash
    ) external onlyRole(GOVERNOR_ROLE) {
        address currentOwner = _owners[tokenId];
        if (currentOwner == address(0)) revert TitleDoesNotExist(tokenId);
        if (_titleStates[tokenId].status == TitleStatus.Revoked) revert TitleAlreadyRevoked(tokenId);
        if (bytes(gazetteNumber).length == 0) revert InvalidGazetteNumber();
        if (reasonHash == bytes32(0)) revert InvalidReasonHash();

        uint64 revokedAt = uint64(block.timestamp);

        _titleStates[tokenId].status = TitleStatus.Revoked;
        _revocationRecords[tokenId] = RevocationRecord({
            revoked: true,
            ground: ground,
            gazetteNumber: gazetteNumber,
            reasonHash: reasonHash,
            revokedAt: revokedAt,
            revokedBy: msg.sender,
            ownerAtRevocation: currentOwner
        });

        emit TitleRevoked(
            tokenId,
            _issuanceRecords[tokenId].parcelIdHash,
            ground,
            gazetteNumber,
            reasonHash,
            currentOwner,
            msg.sender,
            revokedAt
        );
    }

    // -------------------------------------------------------------------------
    // View / Query Functions
    // -------------------------------------------------------------------------

    function computeParcelIdHash(string calldata parcelId) public pure returns (bytes32) {
        if (bytes(parcelId).length == 0) revert InvalidParcelId();
        return keccak256(abi.encodePacked(parcelId));
    }

    function getTokenIdByParcelId(string calldata parcelId) external view returns (uint256) {
        return _parcelToTokenId[computeParcelIdHash(parcelId)];
    }

    function getTokenIdByParcelHash(bytes32 parcelIdHash) external view returns (uint256) {
        return _parcelToTokenId[parcelIdHash];
    }

    function isParcelRegistered(string calldata parcelId) external view returns (bool) {
        return _parcelToTokenId[computeParcelIdHash(parcelId)] != 0;
    }

    function getOracleAttestation(
        string calldata parcelId
    ) external view returns (OracleAttestationRecord memory) {
        return _oracleAttestations[computeParcelIdHash(parcelId)];
    }

    function getTitleIssuance(uint256 tokenId) external view returns (TitleIssuanceRecord memory) {
        if (_owners[tokenId] == address(0)) revert TitleDoesNotExist(tokenId);
        return _issuanceRecords[tokenId];
    }

    function getTitleState(uint256 tokenId) external view returns (TitleState memory) {
        if (_owners[tokenId] == address(0)) revert TitleDoesNotExist(tokenId);
        return _titleStates[tokenId];
    }

    function getRevocationRecord(uint256 tokenId) external view returns (RevocationRecord memory) {
        if (_owners[tokenId] == address(0)) revert TitleDoesNotExist(tokenId);
        return _revocationRecords[tokenId];
    }

    function getTransferHistory(uint256 tokenId) external view returns (TransferRecord[] memory) {
        if (_owners[tokenId] == address(0)) revert TitleDoesNotExist(tokenId);
        return _transferHistory[tokenId];
    }

    function isTitleRevoked(uint256 tokenId) external view returns (bool) {
        if (_owners[tokenId] == address(0)) revert TitleDoesNotExist(tokenId);
        return _titleStates[tokenId].status == TitleStatus.Revoked;
    }

    function totalMintedTitles() external view returns (uint256) {
        return _nextTokenId - 1;
    }

    // -------------------------------------------------------------------------
    // Internal Helpers
    // -------------------------------------------------------------------------

    function _checkOnERC721Received(
        address operator,
        address from,
        address to,
        uint256 tokenId,
        bytes memory data
    ) private {
        if (to.code.length > 0) {
            try IERC721Receiver(to).onERC721Received(operator, from, tokenId, data) returns (
                bytes4 retval
            ) {
                if (retval != IERC721Receiver.onERC721Received.selector) {
                    revert ERC721InvalidReceiver(to);
                }
            } catch (bytes memory reason) {
                if (reason.length == 0) {
                    revert ERC721InvalidReceiver(to);
                } else {
                    assembly ("memory-safe") {
                        revert(add(32, reason), mload(reason))
                    }
                }
            }
        }
    }

    function _toString(uint256 value) private pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }
}
