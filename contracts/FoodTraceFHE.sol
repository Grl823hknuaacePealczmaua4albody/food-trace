// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { FHE, euint32, ebool } from "@fhevm/solidity/lib/FHE.sol";
import { SepoliaConfig } from "@fhevm/solidity/config/ZamaConfig.sol";

contract FoodTraceFHE is SepoliaConfig {
    struct EncryptedBatch {
        uint256 batchId;
        euint32 encryptedOrigin;
        euint32 encryptedProductionDate;
        euint32 encryptedExpirationDate;
        uint256 timestamp;
    }

    struct DecryptedBatch {
        string origin;
        string productionDate;
        string expirationDate;
        bool isRevealed;
    }

    uint256 public batchCount;
    mapping(uint256 => EncryptedBatch) public encryptedBatches;
    mapping(uint256 => DecryptedBatch) public decryptedBatches;

    mapping(string => euint32) private encryptedOriginCount;
    string[] private originList;

    mapping(uint256 => uint256) private requestToBatchId;

    event BatchSubmitted(uint256 indexed batchId, uint256 timestamp);
    event DecryptionRequested(uint256 indexed batchId);
    event BatchDecrypted(uint256 indexed batchId);

    modifier onlyParticipant(uint256 batchId) {
        _;
    }

    function submitEncryptedBatch(
        euint32 encryptedOrigin,
        euint32 encryptedProductionDate,
        euint32 encryptedExpirationDate
    ) public {
        batchCount += 1;
        uint256 newId = batchCount;

        encryptedBatches[newId] = EncryptedBatch({
            batchId: newId,
            encryptedOrigin: encryptedOrigin,
            encryptedProductionDate: encryptedProductionDate,
            encryptedExpirationDate: encryptedExpirationDate,
            timestamp: block.timestamp
        });

        decryptedBatches[newId] = DecryptedBatch({
            origin: "",
            productionDate: "",
            expirationDate: "",
            isRevealed: false
        });

        emit BatchSubmitted(newId, block.timestamp);
    }

    function requestBatchDecryption(uint256 batchId) public onlyParticipant(batchId) {
        EncryptedBatch storage batch = encryptedBatches[batchId];
        require(!decryptedBatches[batchId].isRevealed, "Already decrypted");

        bytes32[] memory ciphertexts = new bytes32[](3);
        ciphertexts[0] = FHE.toBytes32(batch.encryptedOrigin);
        ciphertexts[1] = FHE.toBytes32(batch.encryptedProductionDate);
        ciphertexts[2] = FHE.toBytes32(batch.encryptedExpirationDate);

        uint256 reqId = FHE.requestDecryption(ciphertexts, this.decryptBatch.selector);
        requestToBatchId[reqId] = batchId;

        emit DecryptionRequested(batchId);
    }

    function decryptBatch(uint256 requestId, bytes memory cleartexts, bytes memory proof) public {
        uint256 batchId = requestToBatchId[requestId];
        require(batchId != 0, "Invalid request");

        EncryptedBatch storage eBatch = encryptedBatches[batchId];
        DecryptedBatch storage dBatch = decryptedBatches[batchId];
        require(!dBatch.isRevealed, "Already decrypted");

        FHE.checkSignatures(requestId, cleartexts, proof);

        string[] memory results = abi.decode(cleartexts, (string[]));
        dBatch.origin = results[0];
        dBatch.productionDate = results[1];
        dBatch.expirationDate = results[2];
        dBatch.isRevealed = true;

        if (!FHE.isInitialized(encryptedOriginCount[dBatch.origin])) {
            encryptedOriginCount[dBatch.origin] = FHE.asEuint32(0);
            originList.push(dBatch.origin);
        }
        encryptedOriginCount[dBatch.origin] = FHE.add(
            encryptedOriginCount[dBatch.origin],
            FHE.asEuint32(1)
        );

        emit BatchDecrypted(batchId);
    }

    function getDecryptedBatch(uint256 batchId) public view returns (string memory, string memory, string memory, bool) {
        DecryptedBatch storage batch = decryptedBatches[batchId];
        return (batch.origin, batch.productionDate, batch.expirationDate, batch.isRevealed);
    }

    function getEncryptedOriginCount(string memory origin) public view returns (euint32) {
        return encryptedOriginCount[origin];
    }

    function requestOriginCountDecryption(string memory origin) public {
        euint32 count = encryptedOriginCount[origin];
        require(FHE.isInitialized(count), "Origin not found");

        bytes32[] memory ciphertexts = new bytes32[](1);
        ciphertexts[0] = FHE.toBytes32(count);

        uint256 reqId = FHE.requestDecryption(ciphertexts, this.decryptOriginCount.selector);
        requestToBatchId[reqId] = bytes32ToUint(keccak256(abi.encodePacked(origin)));
    }

    function decryptOriginCount(uint256 requestId, bytes memory cleartexts, bytes memory proof) public {
        uint256 originHash = requestToBatchId[requestId];
        string memory origin = getOriginFromHash(originHash);

        FHE.checkSignatures(requestId, cleartexts, proof);
        uint32 count = abi.decode(cleartexts, (uint32));
    }

    function bytes32ToUint(bytes32 b) private pure returns (uint256) {
        return uint256(b);
    }

    function getOriginFromHash(uint256 hash) private view returns (string memory) {
        for (uint i = 0; i < originList.length; i++) {
            if (bytes32ToUint(keccak256(abi.encodePacked(originList[i]))) == hash) {
                return originList[i];
            }
        }
        revert("Origin not found");
    }
}
