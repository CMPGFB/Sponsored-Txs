// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/ECDSAUpgradeable.sol";

contract SponsoredForwarder is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    ERC165Upgradeable,
    UUPSUpgradeable
{
    using ECDSAUpgradeable for bytes32;

    enum ChangeType { RelayerAuthorization, MaxGasLimitUpdate }

    struct ForwardRequest {
        address from;
        address to;
        uint256 value;
        uint256 gas;
        uint256 nonce;
        bytes data;
    }

    // ------------------------- Storage -------------------------
    mapping(address => uint256) private _nonces;
    uint256 public sponsorshipBalance;
    mapping(address => bool) public authorizedRelayers;

    uint256 public constant EXECUTE_GAS_OVERHEAD = 50_000;
    uint256 public maxGasLimit;
    uint256 public maxWithdrawalAmount;
    uint256 public constant CHANGE_DELAY = 1 days;

    // EIP-712 domain
    bytes32 private constant _EIP712_DOMAIN_TYPE_HASH = keccak256(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
    );
    bytes32 private DOMAIN_SEPARATOR;

    // EIP-2771 interface ID (custom usage here)
    bytes4 private constant _EIP2771_INTERFACE_ID = 0x01ffc9a7;

    // Typehash for ForwardRequest
    bytes32 private constant TYPEHASH = keccak256(
        "ForwardRequest(address from,address to,uint256 value,uint256 gas,uint256 nonce,bytes data)"
    );

    // ------------------------- Events -------------------------
    event SponsorshipFunded(address indexed funder, uint256 amount);
    event SponsorshipWithdrawn(address indexed recipient, uint256 amount);
    event Executed(
        address indexed from,
        address indexed to,
        address indexed relayer,
        uint256 gasUsed,
        uint256 gasCost,
        uint256 requestedGas,
        bool success,
        bytes returndata
    );
    event RelayerStatusChanged(address indexed relayer, bool authorized);
    event MaxGasLimitUpdated(uint256 oldLimit, uint256 newLimit);
    event ChangeScheduled(
        ChangeType changeType,
        address indexed relayer,
        bool authorized,
        uint256 newMaxGasLimit,
        uint256 delay
    );
    event ChangeExecuted(
        ChangeType changeType,
        address indexed relayer,
        bool authorized,
        uint256 newMaxGasLimit
    );

    // ------------------------- Errors -------------------------
    error UnauthorizedRelayer();
    error InvalidSignatureOrNonce();
    error GasLimitExceedsMaximum();
    error SelfCallsNotAllowed();
    error InsufficientSponsorshipFunds();
    error ChangeNotYetDue();
    error MaxGasLimitTooLow();
    error WithdrawalAmountExceedsLimit();
    error InsufficientFunds();

    // ------------------------- Initializer -------------------------
    /**
     * @dev Instead of a constructor, we use an initializer for upgradeable contracts.
     * If your local version of `__Ownable_init` requires an address parameter,
     * pass `_msgSender()` here. 
     */
    function initialize() external initializer {
        // Some versions of OwnableUpgradeable require __Ownable_init(_msgSender())
        // If your local library uses the older version, you can revert to __Ownable_init() with no arguments.
        __Ownable_init(_msgSender());  
        __ReentrancyGuard_init();
        __ERC165_init();
        __UUPSUpgradeable_init();

        // Example default settings
        authorizedRelayers[_msgSender()] = true;
        maxGasLimit = 1_000_000;
        maxWithdrawalAmount = 10 ether;

        // EIP-712 domain separator
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                _EIP712_DOMAIN_TYPE_HASH,
                keccak256("SponsoredForwarder"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );

        emit RelayerStatusChanged(_msgSender(), true);
    }

    // ------------------------- UUPS Authorization -------------------------
    /**
     * @dev Required by UUPS to authorize upgrades. Restrict to contract owner.
     */
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyOwner
    {}

    // ------------------------- Scheduled Changes -------------------------
    function scheduleRelayerAuthorization(address relayer, bool authorized) external onlyOwner {
        emit ChangeScheduled(
            ChangeType.RelayerAuthorization,
            relayer,
            authorized,
            maxGasLimit,
            block.timestamp + CHANGE_DELAY
        );
    }

    function executeRelayerAuthorization(address relayer, bool authorized, uint256 scheduledTime) external onlyOwner {
        if (scheduledTime > block.timestamp) revert ChangeNotYetDue();
        authorizedRelayers[relayer] = authorized;
        emit ChangeExecuted(ChangeType.RelayerAuthorization, relayer, authorized, maxGasLimit);
    }

    function scheduleMaxGasLimit(uint256 newMaxGasLimit) external onlyOwner {
        if (newMaxGasLimit <= EXECUTE_GAS_OVERHEAD) revert MaxGasLimitTooLow();
        emit ChangeScheduled(
            ChangeType.MaxGasLimitUpdate,
            address(0),
            false,
            newMaxGasLimit,
            block.timestamp + CHANGE_DELAY
        );
    }

    function executeMaxGasLimit(uint256 newMaxGasLimit, uint256 scheduledTime) external onlyOwner {
        if (scheduledTime > block.timestamp) revert ChangeNotYetDue();
        uint256 oldLimit = maxGasLimit;
        maxGasLimit = newMaxGasLimit;
        emit MaxGasLimitUpdated(oldLimit, newMaxGasLimit);
    }

    // ------------------------- Sponsorship -------------------------
    function fundSponsorship() external payable {
        if (msg.value == 0) revert InsufficientFunds();
        sponsorshipBalance += msg.value;
        emit SponsorshipFunded(_msgSender(), msg.value);
    }

    function withdrawSponsorship(uint256 amount) external onlyOwner {
        if (amount > sponsorshipBalance) revert InsufficientSponsorshipFunds();
        if (amount > maxWithdrawalAmount) revert WithdrawalAmountExceedsLimit();

        sponsorshipBalance -= amount;
        payable(owner()).transfer(amount);
        emit SponsorshipWithdrawn(owner(), amount);
    }

    // ------------------------- Meta Transaction Logic -------------------------
    function getNonce(address from) external view returns (uint256) {
        return _nonces[from];
    }

    function verify(ForwardRequest calldata req, bytes calldata signature)
        public
        view
        returns (bool)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                TYPEHASH,
                req.from,
                req.to,
                req.value,
                req.gas,
                req.nonce,
                keccak256(req.data)
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
        address signer = digest.recover(signature);

        if (signer != req.from) return false;
        if (_nonces[req.from] != req.nonce) return false;
        return true;
    }

    function execute(ForwardRequest calldata req, bytes calldata signature)
        external
        nonReentrant
        returns (bool success, bytes memory returndata)
    {
        if (!authorizedRelayers[_msgSender()]) revert UnauthorizedRelayer();
        if (!verify(req, signature)) revert InvalidSignatureOrNonce();
        if (req.gas > maxGasLimit) revert GasLimitExceedsMaximum();
        if (req.to == address(this)) revert SelfCallsNotAllowed();

        // Bump user nonce to prevent replay
        _nonces[req.from] = req.nonce + 1;

        uint256 initialGas = gasleft();

        // Execute the target call
        (success, returndata) = req.to.call{gas: req.gas, value: req.value}(
            abi.encodePacked(req.data, req.from)
        );

        // Calculate total gas used
        uint256 gasUsed = initialGas - gasleft() + EXECUTE_GAS_OVERHEAD;
        uint256 gasCost = gasUsed * tx.gasprice;

        if (gasCost > sponsorshipBalance) revert InsufficientSponsorshipFunds();
        sponsorshipBalance -= gasCost;

        // Pay the relayer for their gas
        payable(_msgSender()).transfer(gasCost);

        emit Executed(
            req.from,
            req.to,
            _msgSender(),
            gasUsed,
            gasCost,
            req.gas,
            success,
            returndata
        );
        return (success, returndata);
    }

    // ------------------------- EIP-165 and EIP-2771 -------------------------
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC165Upgradeable)
        returns (bool)
    {
        return
            interfaceId == _EIP2771_INTERFACE_ID ||
            super.supportsInterface(interfaceId);
    }

    // ------------------------- Fallback -------------------------
    receive() external payable {
        sponsorshipBalance += msg.value;
        emit SponsorshipFunded(_msgSender(), msg.value);
    }
}
