#!/usr/bin/env bash
#
# survey.sh -- regenerate the on-chain evidence table in FINDINGS.md.
#
# Every factual claim in FINDINGS.md must be reproducible by running this script.
# A stale claim in that file is the one failure mode that would sink this repo's
# credibility, so re-run this before publishing anything that cites it.
#
#   usage:  ./script/survey.sh [rpc-url]
#
# NOTE ON BLOCK PINNING
# ---------------------
# The public Robinhood Chain RPC is NOT an archive node. Measured retention is
# ~6,000 blocks at ~100ms per block, i.e. roughly TEN MINUTES of historical
# state. Any `--block <n>` query older than that fails with:
#
#   error code -32000: metadata is not found
#
# So this script reads at `latest` and records the block it observed, rather
# than pinning. Reproducing an exact historical reading requires a third-party
# archive endpoint. See FINDINGS.md.

set -uo pipefail

RPC="${1:-${RH_RPC_URL:-https://rpc.mainnet.chain.robinhood.com}}"

command -v cast >/dev/null || { echo "error: foundry 'cast' not found on PATH" >&2; exit 1; }

BLOCK=$(cast block-number --rpc-url "$RPC") || { echo "error: cannot reach $RPC" >&2; exit 1; }
CHAIN=$(cast chain-id --rpc-url "$RPC")

echo "# ERC-8056 on-chain survey"
echo "# rpc      : $RPC"
echo "# chain id : $CHAIN"
echo "# block    : $BLOCK"
echo "# utc      : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo

# symbol:address -- canonical Robinhood Stock Tokens, plus two plain ERC-20s and
# one impostor. Addresses are canonical per docs.robinhood.com/chain/contracts.
TOKENS=(
  "AAPL:0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9"
  "TSLA:0x322F0929c4625eD5bAd873c95208D54E1c003b2d"
  "NVDA:0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC"
  "MSFT:0xe93237C50D904957Cf27E7B1133b510C669c2e74"
  "AMZN:0x12f190a9F9d7D37a250758b26824B97CE941bF54"
  "GOOGL:0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3"
  "META:0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35"
  "NFLX:0xE0444EF8BF4eD74f74FD73686e2ddF4C1c5591E8"
  "SPY:0x117cc2133c37B721F49dE2A7a74833232B3B4C0C"
  "QQQ:0xD5f3879160bc7c32ebb4dC785F8a4F505888de68"
  "JNJ:0x03DfbBE0AC4E7bCDaFd08eD41A400326B77D8c80"
  "XOM:0xf9B46d3D1B22199D4D1025a9cEDB540A33F1a2d5"
  "PFE:0x7066A64c24e4206CD62E83bf198c1E7EB361F51e"
  "USDG:0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168"
  "WETH:0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73"
  "loxAAPL:0xDa62854B8Ae99beb09ca2A9950317b75FaD28f48"
)

_call() { cast call "$1" "$2" --rpc-url "$RPC" 2>/dev/null | awk '{print $1}'; }

printf "%-8s %-44s %-22s %-12s %-7s %s\n" "SYMBOL" "ADDRESS" "uiMultiplier" "effectiveAt" "paused" "8056?"
printf "%-8s %-44s %-22s %-12s %-7s %s\n" "------" "-------" "------------" "-----------" "------" "-----"

for entry in "${TOKENS[@]}"; do
  sym="${entry%%:*}"; addr="${entry##*:}"

  supports=$(cast call "$addr" "supportsInterface(bytes4)(bool)" 0xa60bf13d --rpc-url "$RPC" 2>/dev/null | awk '{print $1}')
  [ -z "$supports" ] && supports="no-erc165"

  mult=$(_call "$addr" "uiMultiplier()(uint256)");   [ -z "$mult" ] && mult="-"
  eff=$(_call "$addr" "effectiveAt()(uint256)");     [ -z "$eff" ]  && eff="-"
  paused=$(_call "$addr" "oraclePaused()(bool)");    [ -z "$paused" ] && paused="-"

  printf "%-8s %-44s %-22s %-12s %-7s %s\n" "$sym" "$addr" "$mult" "$eff" "$paused" "$supports"
done

echo
echo "# ERC-165 probe on AAPL (spec-published interface ids)"
for pair in "0xa60bf13d:IScaledUIAmount" \
            "0x4bd27648:IScaledUIAmountNewUIMultiplier" \
            "0x57854fc3:IScaledUIAmountConversion" \
            "0xd890fd71:IScaledUIAmountBalances" \
            "0x01ffc9a7:IERC165" \
            "0xffffffff:ERC165-invalid-sentinel"; do
  id="${pair%%:*}"; nm="${pair##*:}"
  r=$(cast call 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9 "supportsInterface(bytes4)(bool)" "$id" --rpc-url "$RPC" 2>/dev/null | awk '{print $1}')
  printf "  %-10s %-36s -> %s\n" "$id" "$nm" "${r:-error}"
done

echo
echo "# AAPL supply divergence (raw vs share-equivalent)"
ts=$(_call 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9 "totalSupply()(uint256)")
tsui=$(_call 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9 "totalSupplyUI()(uint256)")
echo "  totalSupply()   = $ts"
echo "  totalSupplyUI() = $tsui"

echo
echo "# Event topic0 hashes -- spec name vs the name actually emitted"
echo "  TransferWithUIAmount  (ERC-8056 spec) = $(cast keccak 'TransferWithUIAmount(address,address,uint256,uint256)')"
echo "  TransferWithScaledUI  (emitted live)  = $(cast keccak 'TransferWithScaledUI(address,address,uint256,uint256)')"
echo "  UIMultiplierUpdated                   = $(cast keccak 'UIMultiplierUpdated(uint256,uint256,uint256)')"
