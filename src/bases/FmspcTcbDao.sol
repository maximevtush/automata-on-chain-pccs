// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PcsDao} from "./PcsDao.sol";
import {DaoBase} from "./DaoBase.sol";
import {SigVerifyBase} from "./SigVerifyBase.sol";

import {CA, AttestationRequestData, AttestationRequest} from "../Common.sol";
import {
    FmspcTcbHelper,
    TcbInfoJsonObj,
    TcbInfoBasic,
    TCBLevelsObj,
    TDXModule,
    TDXModuleIdentity
} from "../helpers/FmspcTcbHelper.sol";

/**
 * @title FMSPC TCB Data Access Object
 * @notice This contract is heavily inspired by Section 4.2.3 in the Intel SGX PCCS Design Guidelines
 * https://download.01.org/intel-sgx/sgx-dcap/1.19/linux/docs/SGX_DCAP_Caching_Service_Design_Guide.pdf
 * @dev should extends this contract and use the provided read/write methods to interact with TCBInfo JSON
 * data published on-chain.
 */
abstract contract FmspcTcbDao is DaoBase, SigVerifyBase {
    PcsDao public Pcs;
    FmspcTcbHelper public FmspcTcbLib;

    /// @notice retrieves the attestationId of the attested FMSPC TCBInfo from the registry
    /// key: keccak256(type ++ FMSPC ++ version)
    /// @notice the schema of the attested data is dependent on the version of TCBInfo:
    /// For TCBInfoV2, it consists of the ABI-encoded tuple of:
    /// (TcbInfoBasic, TCBLevelsObj[], string tcbInfo, bytes signature)
    /// For TCBInfoV3, it consists of the abi-encoded tuple of:
    /// (TcbInfoBasic, TDXModule, TDXModuleIdentity[], TCBLevelsObj, string tcbInfo, bytes signature)
    /// See {{ FmspcTcbHelper.sol }} to learn more about FMSPC TCB related struct definitions.
    mapping(bytes32 => bytes32) public fmspcTcbInfoAttestations;

    constructor(address _pcs, address _fmspcHelper, address _x509Helper) SigVerifyBase(_x509Helper) {
        Pcs = PcsDao(_pcs);
        FmspcTcbLib = FmspcTcbHelper(_fmspcHelper);
    }

    error Invalid_TCB_Cert_Signature();
    error TCB_Expired();

    /**
     * @dev overwrite this method to define the schemaID for the attestation of TCBInfo
     */
    function fmpscTcbV2SchemaID() public view virtual returns (bytes32 FMSPC_TCB_V2_SCHEMA_ID);

    /**
     * @dev overwrite this method to define the schemaID for the attestation of TCBInfo
     */
    function fmpscTcbV3SchemaID() public view virtual returns (bytes32 FMSPC_TCB_V3_SCHEMA_ID);

    /**
     * @dev implement logic to validate and attest TCBInfo
     * @param req structure as defined by EAS
     * https://github.com/ethereum-attestation-service/eas-contracts/blob/52af661748bde9b40ae782907702f885852bc149/contracts/IEAS.sol#L9C1-L23C2
     * @return attestationId
     */
    function _attestTcb(AttestationRequest memory req, bytes32 hash) internal virtual returns (bytes32 attestationId);

    /**
     * @notice Section 4.2.3 (getTcbInfo)
     * @notice Queries TCB Info for the given FMSPC
     * @param tcbType 0: SGX, 1: TDX
     * https://github.com/intel/SGXDataCenterAttestationPrimitives/blob/39989a42bbbb0c968153a47254b6de79a27eb603/QuoteVerification/QVL/Src/AttestationParsers/src/Json/TcbInfo.cpp#L46-L47
     * @param fmspc FMSPC
     * @param version v2 or v3
     * https://github.com/intel/SGXDataCenterAttestationPrimitives/blob/39989a42bbbb0c968153a47254b6de79a27eb603/QuoteVerification/QVL/Src/AttestationParsers/include/SgxEcdsaAttestation/AttestationParsers.h#L241-L248
     * @return tcbObj See {FmspcTcbHelper.sol} to learn more about the structure definition
     */
    function getTcbInfo(uint256 tcbType, string calldata fmspc, uint256 version)
        external
        view
        returns (TcbInfoJsonObj memory tcbObj)
    {
        bytes32 attestationId = _getAttestationId(tcbType, fmspc, version);
        if (attestationId != bytes32(0)) {
            bytes memory attestedTcbData = getAttestedData(attestationId);
            if (version < 3) {
                (,, tcbObj.tcbInfoStr, tcbObj.signature) =
                    abi.decode(attestedTcbData, (TcbInfoBasic, TCBLevelsObj[], string, bytes));
            } else {
                (,,,, tcbObj.tcbInfoStr, tcbObj.signature) = abi.decode(
                    attestedTcbData, (TcbInfoBasic, TDXModule, TDXModuleIdentity[], TCBLevelsObj[], string, bytes)
                );
            }
        }
    }

    /**
     * @notice Section 4.2.9 (upsertEnclaveIdentity)
     * @dev Attestation Registry Entrypoint Contracts, such as Portals on Verax are responsible
     * @dev for performing ECDSA verification on the provided TCBInfo
     * against the Signing CA key prior to attestations
     * @param tcbInfoObj See {FmspcTcbHelper.sol} to learn more about the structure definition
     */
    function upsertFmspcTcb(TcbInfoJsonObj calldata tcbInfoObj) external returns (bytes32 attestationId) {
        _validateTcbInfo(tcbInfoObj);
        (AttestationRequest memory req, TcbInfoBasic memory tcbInfo) = _buildTcbAttestationRequest(tcbInfoObj);
        bytes32 hash = sha256(bytes(tcbInfoObj.tcbInfoStr));
        attestationId = _attestTcb(req, hash);
        fmspcTcbInfoAttestations[keccak256(abi.encodePacked(tcbInfo.tcbType, tcbInfo.fmspc, tcbInfo.version))] =
            attestationId;
    }

    /**
     * @notice Fetches the TCBInfo Issuer Chain
     * @return signingCert - DER encoded Intel TCB Signing Certificate
     * @return rootCert - DER encoded Intel SGX Root CA
     */
    function getTcbIssuerChain() public view returns (bytes memory signingCert, bytes memory rootCert) {
        bytes32 signingCertAttestationId = Pcs.pcsCertAttestations(CA.SIGNING);
        bytes32 rootCertAttestationId = Pcs.pcsCertAttestations(CA.ROOT);
        signingCert = getAttestedData(signingCertAttestationId);
        rootCert = getAttestedData(rootCertAttestationId);
    }

    /**
     * @notice computes the key that maps to the corresponding attestation ID
     */
    function _getAttestationId(uint256 tcbType, string memory fmspc, uint256 version)
        private
        view
        returns (bytes32 attestationId)
    {
        attestationId = fmspcTcbInfoAttestations[keccak256(abi.encodePacked(uint8(tcbType), fmspc, uint32(version)))];
    }

    /**
     * @notice builds an EAS compliant attestation request
     */
    function _buildTcbAttestationRequest(TcbInfoJsonObj calldata tcbInfoObj)
        private
        view
        returns (AttestationRequest memory req, TcbInfoBasic memory tcbInfo)
    {
        bytes memory attestationData;
        (attestationData, tcbInfo) = _buildAttestationData(tcbInfoObj.tcbInfoStr, tcbInfoObj.signature);
        bytes32 predecessorAttestationId = _getAttestationId(tcbInfo.tcbType, tcbInfo.fmspc, tcbInfo.version);
        if (block.timestamp < tcbInfo.issueDate || block.timestamp > tcbInfo.nextUpdate) {
            revert TCB_Expired();
        }
        AttestationRequestData memory reqData = AttestationRequestData({
            recipient: msg.sender,
            expirationTime: uint64(tcbInfo.nextUpdate),
            revocable: true,
            refUID: predecessorAttestationId,
            data: attestationData,
            value: 0
        });
        bytes32 schemaId = tcbInfo.version < 3 ? fmpscTcbV2SchemaID() : fmpscTcbV3SchemaID();
        req = AttestationRequest({schema: schemaId, data: reqData});
    }

    function _buildAttestationData(string memory tcbInfoStr, bytes memory signature)
        private
        view
        returns (bytes memory attestationData, TcbInfoBasic memory tcbInfo)
    {
        (, TCBLevelsObj[] memory tcbLevels) = FmspcTcbLib.parseTcbLevels(tcbInfoStr);
        tcbInfo = FmspcTcbLib.parseTcbString(tcbInfoStr);
        if (tcbInfo.version < 3) {
            attestationData = abi.encode(tcbInfo, tcbLevels, tcbInfoStr, signature);
        } else {
            (TDXModule memory module, TDXModuleIdentity[] memory moduleIdentities) =
                FmspcTcbLib.parseTcbTdxModules(tcbInfoStr);
            attestationData = abi.encode(tcbInfo, module, moduleIdentities, tcbLevels, tcbInfoStr, signature);
        }
    }

    function _validateTcbInfo(TcbInfoJsonObj calldata tcbInfoObj) private view {
        // Get TCB Signing Cert
        bytes32 tcbSigningAttestationId = Pcs.pcsCertAttestations(CA.SIGNING);
        bytes memory signingDer = getAttestedData(tcbSigningAttestationId);

        // Validate signature
        bool sigVerified = verifySignature(sha256(bytes(tcbInfoObj.tcbInfoStr)), tcbInfoObj.signature, signingDer);

        if (!sigVerified) {
            revert Invalid_TCB_Cert_Signature();
        }
    }
}
