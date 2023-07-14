// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC1271.sol";
import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin-upgrades/contracts/access/OwnableUpgradeable.sol";
import "@openzeppelin-upgrades/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "./DelegationManagerStorage.sol";
import "../permissions/Pausable.sol";
import "./Slasher.sol";

/**
 * @title The interface for the primary delegation contract for EigenLayer.
 * @author Layr Labs, Inc.
 * @notice Terms of Service: https://docs.eigenlayer.xyz/overview/terms-of-service
 * @notice  This is the contract for delegation in EigenLayer. The main functionalities of this contract are
 * - enabling anyone to register as an operator in EigenLayer
 * - allowing operators to specify parameters related to stakers who delegate to them
 * - enabling any staker to delegate its stake to the operator of its choice
 * - enabling a staker to undelegate its assets from an operator (performed as part of the withdrawal process, initiated through the StrategyManager)
 */
contract DelegationManager is Initializable, OwnableUpgradeable, Pausable, DelegationManagerStorage {
    // index for flag that pauses new delegations when set
    uint8 internal constant PAUSED_NEW_DELEGATION = 0;

    // bytes4(keccak256("isValidSignature(bytes32,bytes)")
    bytes4 internal constant ERC1271_MAGICVALUE = 0x1626ba7e;

    // chain id at the time of contract deployment
    uint256 internal immutable ORIGINAL_CHAIN_ID;

    /// @notice Simple permission for functions that are only callable by the StrategyManager contract.
    modifier onlyStrategyManager() {
        require(msg.sender == address(strategyManager), "onlyStrategyManager");
        _;
    }

    // INITIALIZING FUNCTIONS
    constructor(IStrategyManager _strategyManager, ISlasher _slasher) 
        DelegationManagerStorage(_strategyManager, _slasher)
    {
        _disableInitializers();
        ORIGINAL_CHAIN_ID = block.chainid;
    }

    function initialize(address initialOwner, IPauserRegistry _pauserRegistry, uint256 initialPausedStatus)
        external
        initializer
    {
        _initializePauser(_pauserRegistry, initialPausedStatus);
        _DOMAIN_SEPARATOR = _calculateDomainSeparator();
        _transferOwnership(initialOwner);
    }

    // EXTERNAL FUNCTIONS
    /**
     * @notice Registers the `msg.sender` as an operator in EigenLayer, that stakers can choose to delegate to.
     * @param registeringOperatorDetails is the `OperatorDetails` for the operator.
     * @dev Note that once an operator is registered, they cannot 'deregister' as an operator, and they will forever be considered "delegated to themself".
     * @dev This function will revert if the caller attempts to set their `earningsReceiver` to address(0).
     */
    function registerAsOperator(OperatorDetails calldata registeringOperatorDetails) external {
        require(
            _operatorDetails.earningsReceiver == address(0),
            "DelegationManager.registerAsOperator: operator has already registered"
        );
        _setOperatorDetails(msg.sender, registeringOperatorDetails);
        // TODO: decide if this event is needed (+ details in particular), since we already emit an `OperatorDetailsModified` event in the above internal call
        emit OperatorRegistered(msg.sender, registeringOperatorDetails);
    }

    /**
     * @notice Updates the `msg.sender`'s stored `OperatorDetails`.
     * @param newOperatorDetails is the updated `OperatorDetails` for the operator, to replace their current OperatorDetails`.
     * @dev The `msg.sender` must have previously registered as an operator in EigenLayer via calling the `registerAsOperator` function.
     * @dev This function will revert if the caller attempts to set their `earningsReceiver` to address(0).
     */
    function modifyOperatorDetails(OperatorDetails calldata newOperatorDetails) external {
        _setOperatorDetails(msg.sender, newOperatorDetails);
    }

    /**
     * @notice Called by a staker to delegate its assets to the @param operator.
     * @param operator is the operator to whom the staker (`msg.sender`) is delegating its assets for use in serving applications built on EigenLayer.
     * @param approverSignatureAndExpiry is a parameter that will be used for verifying that the operator approves of this delegation action in the event that:
     * 1) the operator's `delegationApprover` address is set to a non-zero value.
     * AND
     * 2) neither the operator nor their `delegationApprover` is the `msg.sender`, since in the event that the operator or their delegationApprover
     * is the `msg.sender`, then approval is assumed.
     */
    function delegateTo(address operator, SignatureWithExpiry memory approverSignatureAndExpiry) external {
        // go through the internal delegation flow, checking the `approverSignatureAndExpiry` if applicable
        _delegate(msg.sender, operator, approverSignatureAndExpiry);
    }

    /**
     * @notice Delegates from @param staker to @param operator.
     * @notice This function will revert if the current `block.timestamp` is equal to or exceeds @param expiry
     * @dev The @param stakerSignature is used as follows:
     * 1) If `staker` is an EOA, then `stakerSignature` is verified to be a valid ECDSA stakerSignature from `staker`, indicating their intention for this action.
     * 2) If `staker` is a contract, then `stakerSignature` will be checked according to EIP-1271.
     * @param approverSignatureAndExpiry is a parameter that will be used for verifying that the operator approves of this delegation action in the event that:
     * 1) the operator's `delegationApprover` address is set to a non-zero value.
     * AND
     * 2) neither the operator nor their `delegationApprover` is the `msg.sender`, since in the event that the operator or their delegationApprover
     * is the `msg.sender`, then approval is assumed.
     */
    function delegateToBySignature(
        address staker,
        address operator,
        SignatureWithExpiry memory stakerSignatureAndExpiry,
        SignatureWithExpiry memory approverSignatureAndExpiry
    ) external {
        // check the signature expiry
        require(stakerSignatureAndExpiry.expiry >= block.timestamp, "DelegationManager.delegateToBySignature: staker signature expired");
        // calculate the struct hash, then increment `staker`'s nonce
        uint256 currentStakerNonce = stakerNonce[staker];
        bytes32 stakerStructHash = keccak256(abi.encode(STAKER_DELEGATION_TYPEHASH, staker, operator, currentStakerNonce, stakerSignatureAndExpiry.expiry));
        unchecked {
            stakerNonce[staker] = currentStakerNonce + 1;
        }

        // calculate the digest hash
        bytes32 stakerDigestHash = keccak256(abi.encodePacked("\x19\x01", domainSeparator(), stakerStructHash));

        // actually check that the signature is valid
        _checkSignature_EIP1271(staker, stakerDigestHash, stakerSignatureAndExpiry.signature);

        // go through the internal delegation flow, checking the `approverSignatureAndExpiry` if applicable
        _delegate(staker, operator, approverSignatureAndExpiry);
    }

    /**
     * @notice Undelegates `staker` from the operator who they are delegated to.
     * @notice Callable only by the StrategyManager
     * @dev Should only ever be called in the event that the `staker` has no active deposits in EigenLayer.
     * @dev Reverts if the `staker` is also an operator, since operators are not allowed to undelegate from themselves
     */
    function undelegate(address staker) external onlyStrategyManager {
        require(!isOperator(staker), "DelegationManager.undelegate: operators cannot undelegate from themselves");
        emit StakerUndelegated(staker, delegatedTo[staker]);
        delegatedTo[staker] = address(0);
    }

    // TODO: decide if on the right  auth for this. Perhaps could be another address for the operator to specify
    /**
     * @notice Called by the operator or the operator's `delegationApprover` address, in order to forcibly undelegate a staker who is currently delegated to the operator.
     * @param operator The operator who the @param staker is currently delegated to.
     * @dev This function will revert if either:
     * A) The `msg.sender` does not match `operatorDetails(operator).delegationApprover`.
     * OR
     * B) The `staker` is not currently delegated to the `operator`.
     * @dev This function will also revert if the `staker` is the `operator`; operators are considered *permanently* delegated to themselves.
     */
    function forceUndelegation(address staker, address operator) external {
        require(delegatedTo[staker] == operator, "DelegationManager.forceUndelegation: staker is not delegated to operator");
        require(msg.sender == operator || msg.sender == _operatorDetails[operator].delegationApprover,
            "DelegationManager.forceUndelegation: caller must be operator or their delegationApprover");
        strategyManager.forceUndelegation(staker);
    }

    /**
     * @notice *If the staker is actively delegated*, then increases the `staker`'s delegated shares in `strategy` by `shares`. Otherwise does nothing.
     * Called by the StrategyManager whenever new shares are added to a user's share balance.
     * @dev Callable only by the StrategyManager.
     */
    function increaseDelegatedShares(address staker, IStrategy strategy, uint256 shares)
        external
        onlyStrategyManager
    {
        //if the staker is delegated to an operator
        if (isDelegated(staker)) {
            address operator = delegatedTo[staker];

            // add strategy shares to delegate's shares
            operatorShares[operator][strategy] += shares;

            //Calls into operator's delegationTerms contract to update weights of individual staker
            IStrategy[] memory stakerStrategyList = new IStrategy[](1);
            uint256[] memory stakerShares = new uint[](1);
            stakerStrategyList[0] = strategy;
            stakerShares[0] = shares;

            // call into hook in delegationTerms contract
            IDelegationTerms dt = delegationTerms[operator];
            _delegationReceivedHook(dt, staker, stakerStrategyList, stakerShares);
        }
    }

    /**
     * @notice *If the staker is actively delegated*, then decreases the `staker`'s delegated shares in each entry of `strategies` by its respective `shares[i]`. Otherwise does nothing.
     * Called by the StrategyManager whenever shares are decremented from a user's share balance, for example when a new withdrawal is queued.
     * @dev Callable only by the StrategyManager.
     */
    function decreaseDelegatedShares(address staker, IStrategy[] calldata strategies, uint256[] calldata shares)
        external
        onlyStrategyManager
    {
        if (isDelegated(staker)) {
            address operator = delegatedTo[staker];

            // subtract strategy shares from delegate's shares
            uint256 stratsLength = strategies.length;
            for (uint256 i = 0; i < stratsLength;) {
                operatorShares[operator][strategies[i]] -= shares[i];
                unchecked {
                    ++i;
                }
            }

            // call into hook in delegationTerms contract
            IDelegationTerms dt = delegationTerms[operator];
            _delegationWithdrawnHook(dt, staker, strategies, shares);
        }
    }

    // INTERNAL FUNCTIONS
    /**
     * @notice Internal function that sets the @param operator 's parameters in the `_operatorDetails` mapping to @param newOperatorDetails
     * @dev This function will revert if the operator attempts to set their `earningsReceiver` to address(0).
     */
    function _setOperatorDetails(address operator, OperatorDetails calldata newOperatorDetails) internal {
        require(
            newOperatorDetails.earningsReceiver != address(0),
            "DelegationManager._setOperatorDetails: cannot set `earningsReceiver` to zero address"
        );
        _operatorDetails[operator] = newOperatorDetails;
        emit OperatorDetailsModified(msg.sender, newOperatorDetails);
    }

    /**
     * @notice Internal function implementing the delegation *from* `staker` *to* `operator`.
     * @param staker The address to delegate *from* -- this address is delegating control of its own assets.
     * @param operator The address to delegate *to* -- this address is being given power to place the `staker`'s assets at risk on services
     * @dev Ensures that:
     * 1) the `staker` is not already delegated to an operator
     * 2) the `operator` has indeed registered as an operator in EigenLayer
     * 3) the `operator` is not actively frozen
     * 4) if applicable, that the approver signature is valid and non-expired
     */ 
    function _delegate(address staker, address operator, SignatureWithExpiry memory approverSignatureAndExpiry) internal {
        require(isNotDelegated(staker), "DelegationManager._delegate: staker has existing delegation");
        require(isOperator(operator), "DelegationManager._delegate: operator is not registered in EigenLayer");
        require(!slasher.isFrozen(operator), "DelegationManager._delegate: cannot delegate to a frozen operator");

        // fetch the operator's `delegationApprover` address and store it in memory in case we need to use it multiple times
        address delegationApprover = _operatorDetails[operator].delegationApprover;
        /**
         * Check the `delegationApprover`'s signature, if applicable.
         * If the `delegationApprover` is the zero address, then the operator allows all stakers to delegate to them and this verification is skipped.
         * If the `delegationApprover` or the `operator` themselves is the caller, then approval is assumed and signature verification is skipped as well.
         */
        if (delegationApprover != address(0) && msg.sender != delegationApprover && msg.sender != operator) {
            // check the signature expiry
            require(approverSignatureAndExpiry.expiry >= block.timestamp, "DelegationManager._delegate: approver signature expired");

            // calculate the struct hash, then increment `delegationApprover`'s nonce
            uint256 currentApproverNonce = delegationApproverNonce[delegationApprover];
            bytes32 approverStructHash = keccak256(abi.encode(DELEGATION_APPROVAL_TYPEHASH, delegationApprover, operator, currentApproverNonce, approverSignatureAndExpiry.expiry));
            unchecked {
                delegationApproverNonce[delegationApprover] = currentApproverNonce + 1;
            }

            // calculate the digest hash
            bytes32 approverDigestHash = keccak256(abi.encodePacked("\x19\x01", domainSeparator(), approverStructHash));

            // actually check that the signature is valid
            _checkSignature_EIP1271(delegationApprover, approverDigestHash, approverSignatureAndExpiry.approverSignature);
        }

        // record the delegation relation between the staker and operator, and emit an event
        delegatedTo[staker] = operator;
        emit StakerDelegated(staker, operator);
    }

    function _checkSignature_EIP1271(address signer, bytes32 digestHash, bytes memory signature) internal {
        /**
         * check validity of signature:
         * 1) if `signer` is an EOA, then `signature` must be a valid ECDSA signature from `signer`,
         * indicating their intention for this action
         * 2) if `signer` is a contract, then `signature` must will be checked according to EIP-1271
         */
        if (Address.isContract(signer)) {
            require(IERC1271(signer).isValidSignature(digestHash, signature) == ERC1271_MAGICVALUE,
                "DelegationManager._signatureCheck_EIP1271Compatible: ERC1271 signature verification failed");
        } else {
            require(ECDSA.recover(digestHash, signature) == signer,
                "DelegationManager._signatureCheck_EIP1271Compatible: sig not from signer");
        }
    }

    // VIEW FUNCTIONS
    /**
     * @notice Getter function for the current EIP-712 domain separator for this contract.
     * @dev The domain separator will change in the event of a fork that changes the ChainID.
     */
    function domainSeparator() public view returns (bytes32) {
        if (block.chainid == ORIGINAL_CHAIN_ID) {
            return _DOMAIN_SEPARATOR;
        }
        else {
            return _calculateDomainSeparator();
        }
    }

    /// @notice Returns 'true' if `staker` *is* actively delegated, and 'false' otherwise.
    function isDelegated(address staker) public view returns (bool) {
        return (delegatedTo[staker] != address(0));
    }

    /// @notice Returns 'true' if `staker` is *not* actively delegated, and 'false' otherwise.
    function isNotDelegated(address staker) public view returns (bool) {
        return (delegatedTo[staker] == address(0));
    }

    /// @notice Returns if an operator can be delegated to, i.e. the `operator` has previously called `registerAsOperator`.
    function isOperator(address operator) public view returns (bool) {
        return (_operatorDetails[operator].earningsReceiver != address(0));
    }

    /**
     * @notice returns the OperatorDetails of the `operator`.
     * @notice Mapping: operator => OperatorDetails struct
     */
    function operatorDetails(address operator) external view returns (OperatorDetails memory) {
        return _operatorDetails[operator];
    }

    function _calculateDomainSeparator() internal view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_TYPEHASH, keccak256(bytes("EigenLayer")), block.chainid, address(this)));
    }
}
