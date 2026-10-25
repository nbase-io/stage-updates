# stage-updates

[StageUpdater](https://github.com/nbase-io/StageUpdater) 가 받는 업데이트 피드와 설치 파일을 두는 **공개** 저장소입니다.
**손으로 고치지 마세요.** StageUpdater 저장소의 `scripts/publish.sh` 가 관리합니다.

| 무엇 | 어디 |
| --- | --- |
| 피드 (Ed25519 서명) | `feed.json` → GitHub Pages `https://nbase-io.github.io/stage-updates/feed.json` |
| 설치 파일 (dmg · zip) | [Releases](https://github.com/nbase-io/stage-updates/releases), 태그 `<제품>-v<버전>` (예: `stagevpn-v1.0.5`) |

- 한 번 올린 설치 파일은 바꾸거나 지우지 마세요. 피드에 적힌 SHA-256 과 달라져 업데이트가 실패합니다. 문제가 있는 릴리스는 피드에서 빼서 철회합니다.
- `feed.json` 은 서명 키가 있어야 만들 수 있습니다. 이 저장소의 파일을 바꿔도 서명이 맞지 않으면 StageUpdater 가 받지 않습니다.
- 이 저장소에는 웹 페이지를 두지 않습니다(`.nojekyll`, 파일만 제공).
