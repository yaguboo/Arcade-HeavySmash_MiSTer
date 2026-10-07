# Heavy Smash — MiSTer FPGA 코어

> [!IMPORTANT]
> **취미로 만든 프로젝트입니다.**
> 개인이 순전히 취미로 만든 코어입니다. 버그 제보는 반갑게 받지만, **대응할 수도 있고 못 할 수도 있습니다.**
> 업데이트나 지원을 약속하지 않습니다.
>
> **이 코드로 이어서 개발하실 때는 꼭 출처를 남겨 주세요.**
> 이 저장소를 바탕으로 수정하거나 다른 코어를 만드실 때 출처(이 저장소 링크)를 밝혀 주시면 정말 감사하겠습니다.
> 라이선스(GPL-3.0)에 따라 원래의 저작권 표시와 이 프로젝트가 감사를 전한 분들의 출처도 함께 유지해 주세요.

Data East 가 1993 년에 내놓은 핸드볼 게임 **Heavy Smash** 를 MiSTer 에서 돌리는
FPGA 코어입니다. 기판은 DE-0385-2 (DEC-22VO) 이고, 이 코어는 그 기판의 주요
칩을 하나하나 RTL 로 다시 만든 것입니다.

- **메인 CPU — DE156.** 암호화된 ARM 패키지입니다. 처음에는 ARM7TDMI 로
  알려져 있었지만 실제로는 **26 비트 ARM2 계열**입니다 (PC 와 PSR 이 R15 하나를
  나눠 쓰고, `MOVS PC,R14` 로 복귀하며 플래그를 되돌립니다). 이 코어는
  ARMv2a 인 Amber a23 을 CPU 로 쓰고, 프로그램 ROM 복호화는 CPU 의 명령어
  페치 경로 안에서 실시간으로 합니다.
- **타일 — DECO 141** (deco16ic 계열 playfield 두 장). 그래픽 ROM 은 **DECO 56**
  방식으로 암호화되어 있어서 타일을 읽을 때마다 주소 치환·XOR·비트 스왑을
  실시간으로 풉니다.
- **스프라이트 — DECO 52** (decospr 표준 포맷).
- **팔레트** — 32 비트 xBGR 888, 1024 색.
- **사운드** — OKI MSM6295 두 개 (1 MHz / 2 MHz). 두 번째 칩의 샘플 ROM 은 주소
  비트가 섞여 있어서 페치 때 바로잡습니다.
- **EEPROM** — 93C46 (64 x 16). 게임 설정은 DIP 스위치가 아니라 이 EEPROM 에
  저장됩니다.
- 화면 320 x 240, 약 58 Hz.

ROM 은 포함되어 있지 않습니다. MAME 의 표준 ROM 세트를 그대로 읽습니다.

## 지원 게임

| MAME 세트 | 공식 명칭 | 상태 |
|---|---|---|
| `hvysmsh`  | Heavy Smash (Europe version -2, 1993/06/30) | 실기에서 플레이 확인 (2026-09-23), 사운드·스프라이트 수락. 어트랙트 데모 재확인 (2026-10-06) |
| `hvysmsha` | Heavy Smash (Asia version -4, 1993/09/06)   | 실기에서 부팅·어트랙트 데모 확인 (2026-10-06) |
| `hvysmshj` | Heavy Smash (Japan version -2, 1993/06/30)  | 실기에서 부팅·어트랙트 데모 확인 (2026-10-06) |

`.mra` 는 MAME 표준 zip 을 그대로 읽습니다. 클론 세트(`hvysmsha`, `hvysmshj`)는
split 세트이므로 클론 zip 과 부모 `hvysmsh.zip` 이 둘 다 필요합니다.

같은 MAME 드라이버 파일에 들어 있는 **World Cup Volley '95** (`wcvol95`,
`wcvol95j`, `wcvol95x`) 는 지원하지 않습니다. 같은 CPU 를 쓰지만 사운드가
YMZ280B 이고 팔레트 형식(xBGR 555)도 달라서, 사실상 다른 기계입니다.

## 설치 — ROM 만 넣으면 됩니다

이 배포본의 `SD/` 폴더는 MiSTer SD 카드의 루트(`/media/fat/`)와 같은 구조입니다.
**`SD/` 안의 내용을 SD 카드 루트에 그대로 복사**하면 됩니다.

```
SD/_Arcade/cores/HeavySmash.rbf                 코어 (빌드된 비트스트림)
SD/_Arcade/_Kaze's Cores/<게임 이름>.mra    게임 목록 (공식 명칭)
SD/games/mame/필요한_ROM.txt               넣어야 할 ROM zip 목록
```

1. `SD/` 의 내용을 SD 카드 루트에 복사합니다. 기존 파일은 덮어써도 됩니다.
2. 직접 마련한 MAME ROM 세트 zip 을 SD 카드의 `/games/mame/` 에 넣습니다.
   어떤 zip 이 필요한지는 `필요한_ROM.txt` 에 게임별로 적혀 있습니다.
   zip 은 MAME 세트 이름 그대로 두고, 압축을 풀지 않습니다.
3. MiSTer 메뉴에서 **Arcade → `_Kaze's Cores`** 로 들어가 게임을 고릅니다.

- `.rbf` 를 직접 실행하지 말고 `.mra` 로 실행하세요. ROM 로드와 DIP·OSD 기본값이
  `.mra` 에 들어 있습니다.
- 폴더 이름이 `_` 로 시작해야 MiSTer 메뉴에 보입니다. 이름을 바꾸지 마세요.


## 빌드 방법

필요한 것: **Intel Quartus Prime Lite Edition 17.0** (MiSTer 코어 표준 버전). 다른 버전에서도
합성은 될 수 있지만 검증한 버전은 17.0 입니다.

```sh
cd projects/dataeast/heavy_smash/targets/mister
quartus_sh --flow compile HeavySmash
```

결과물은 `projects/dataeast/heavy_smash/targets/mister/output_files/HeavySmash.rbf` 입니다. Quartus GUI 로
`HeavySmash.qpf` 를 열고 Compile 을 눌러도 같습니다.

- 디렉터리 구조를 그대로 유지해야 합니다. 프로젝트 파일이 `../../../../../third_party`,
  `../../../../../platforms/mister/sys` 를 상대 경로로 찾습니다.
- `build_id.v` 는 빌드 시작 때 `platforms/mister/sys/build_id.tcl` 이 자동으로 만듭니다.
- Quartus 17.0 의 fitter 가 드물게 내부 오류로 죽으면서도 정상 종료 코드를 남기는 경우가 있습니다.
  `.rbf` 의 생성 시각과 로그 끝부분을 확인하고, 그런 경우 한 번 더 빌드하면 됩니다.

직접 빌드한 `.rbf` 는 `SD/_Arcade/cores/` 의 같은 이름 파일과 바꿔 넣으면 됩니다.

## 디렉터리 구성

원래 저장소의 상대 경로를 그대로 유지했습니다. 빌드에 실제로 쓰이는 파일만 들어 있습니다.

```
LICENSE                              GPL-3.0 전문
README.md                            이 문서
SD/                                  SD 카드 루트에 복사할 설치 파일 (RBF, MRA, ROM 목록)
projects/dataeast/heavy_smash/
  rtl/                               기판 하드웨어 RTL (ARM 메인 CPU 버스, deco156 복호, 비디오·사운드, 메모리 RTL)
  integration/                       ROM 다운로드 경로 (플랫폼 중립 어댑터)
  targets/mister/                    MiSTer 최상위 (.qpf .qsf .sdc .sv files.qip, PLL)
third_party/                         외부 IP (아래 "감사의 말과 사용한 코드" 참조)
platforms/mister/sys/                MiSTer framework (Template_MiSTer)
```

소스 주석에는 개발 중에 쓴 내부 문서 번호와 측정 기록이 그대로 남아 있습니다. 해당 개발
문서와 측정·분석 도구는 이 배포본에 포함하지 않았습니다. 빌드에는 영향이 없습니다.

## 작업 내역

**2026-09-19 — 소스 조사와 첫 비트스트림**

- MAME 드라이버(`hvysmsh.cpp`)와 그것이 부르는 장치 소스(`deco16ic.cpp`,
  `decospr.cpp`, `deco156.cpp`, `decocrpt.cpp`, OKI, EEPROM, ARM 코어)를 먼저
  옮겨 적고, 메모리 맵·클럭·인터럽트·화면·ROM 배치를 표로 정리한 뒤 구현을
  시작했습니다. 애매한 항목은 FBNeo 로 교차 확인했습니다.
- 보드 전체 RTL, DE156 프로그램 복호화, DECO 56 그래픽 복호화를 구현했습니다.
  두 복호화 엔진은 실제 ROM 덤프를 MAME 의 변환과 대조해 확인했습니다
  (복호 결과 0 번지가 ARM 부트 코드 `EA00000D`).
- 같은 날 첫 비트스트림이 fitter·타이밍을 통과했습니다.

**2026-09-20 — ROM 경로 확인**

- 화면이 검은 채로 멈춰서, 코어 안에 ROM 무결성 프로브와 화면 오버레이를
  만들어 실기에서 데이터 경로를 직접 읽었습니다. 100 MHz 에서 SDRAM tRCD 가
  부족했던 것과, 프로브·CPU 가 ROM 클라이언트를 잘못 공유하던 것을 찾아
  고쳤습니다. 이후 8/8 샘플 dword 와 ROM 전체 합계가 모델과 일치했습니다.

**2026-09-21 — CPU 교체, 그리고 MAME 와 같은 그림**

- 실기에서 CPU 가 이상하게 죽는 원인을 추적하다가, DE156 이 ARM7TDMI 가 아니라
  **26 비트 ARM2** 라는 것을 확인했습니다 (MAME 는 `de156_cpu_device` 를
  `arm2_cpu_device` 로, 26 비트 전용 플래그와 함께 만듭니다). 처음 쓰던
  ARM7TDMI 코어를 내리고, Archie (Acorn Archimedes) MiSTer 코어에서 RISC OS 를
  돌리고 있는 **Amber a23 (ARMv2a)** 으로 바꿨습니다.
- Amber 의 Wishbone 마스터가 ack 클럭에 주소를 다시 잡아 모든 저장이 버스에
  두 번 나가는 문제를 시뮬레이션에서 찾아, 캐시+Wishbone 전단을 이 기판용 메모리
  프런트엔드로 바꿨습니다.
- CPU+버스+EEPROM 이 부팅·초기화 전체에서 MAME 의 쓰기 스트림과 **172,594 건
  전부** 순서·주소·데이터·폭까지 일치했습니다.
- 렌더러를 MAME 그림과 픽셀 단위로 대조하는 시뮬레이션을 만들어 결함 여러 개를
  고쳤고, 어트랙트 6 프레임이 모두 **76,800/76,800 픽셀 일치**했습니다.
  실기 화면도 MAME 프레임과 대조해 같은 그림임을 확인했습니다.
- OKI 샘플 ROM 주소(두 번째 칩의 비트 회전 방향, 뱅크 크기)를 MAME 와 대조해
  바로잡았습니다. 사운드 믹서의 부호 있는 시프트 결함과 24 dB 레벨 차이도
  고쳤습니다.
- 입력 워드가 잘려 코인을 넣을 수 없던 문제, 코인 비트 극성 문제를 고쳤습니다.

**2026-09-22 — 속도**

- 실기에서 게임이 MAME 의 약 0.55 배 속도로 돌았습니다. 측정해 보니 CPU 가
  SDRAM 워드의 71 % 를 명령어 페치에 쓰고 있었습니다. 게임의 실제 페치 패턴을
  측정해 크기를 정한 **8 KB 명령어 캐시**를 넣어 CPU 의 메모리 대기를 64.6 % 에서
  0.08 % 로 줄였고, 실기에서 프레임 속도·BGM 끊김·빠른 장면의 스프라이트 문제가
  한 번에 사라졌습니다.
- OSD 를 표준 구성(화면비, Scandoubler, DIP, Pause, Reset)으로 정리했습니다.

**2026-09-23 — 사운드와 스프라이트 마무리, 1 차 완성**

- BGM 이 MAME 와 다르게 들리던 원인은 볼륨이 아니라, 두 OKI 가 서로 다른
  샘플레이트로 돌아 계단파의 재구성 이미지가 칩마다 30 배 차이 났던 것이었습니다.
  칩별 선형 보간과 약한 프리엠퍼시스를 넣어 대역별 에너지 분포를 MAME 에
  3.5 배 가깝게 맞췄습니다.
- 빠른 장면의 스프라이트 찢어짐은 CPU 가 화면을 그리는 도중에 스프라이트 리스트를
  다시 쓰고 있었기 때문이었습니다. 게임이 매 프레임 건드리는 DMA 레지스터를
  신호로 삼아 리스트를 VBlank 에 그림자 버퍼로 복사하게 했고, 시뮬레이션에서
  찢어짐 노출이 0 이 되었습니다.
- 이 빌드를 실기에서 직접 플레이해 사운드와 스프라이트를 모두 수락했습니다
  (**1 차 완성**). 타이밍은 모든 클럭 도메인에서 MET 입니다.

**2026-10-06 — 세트 정리**

- `.mra` 가 별도로 가공한 zip 없이 MAME 표준 zip 을 그대로 읽도록 바꾸고
  (프로그램 ROM 두 개의 32 비트 인터리브를 `.mra` 안에서 표현),
  Asia·Japan 세트를 추가했습니다. 세 세트 모두 실기에서 부팅과 어트랙트 데모를
  확인했습니다.

## 감사의 말과 사용한 코드

먼저 **MAME 팀**에 깊이 감사드립니다. 이 코어의 거의 모든 동작 — 메모리 맵,
두 단계의 암호화, 타일·스프라이트 포맷, 사운드 배선 — 은 MAME 개발자들이 수십
년에 걸쳐 분석하고 소스로 남겨 둔 지식 위에 서 있습니다. 실제 기판을 대신해
"정답 그림"과 "정답 쓰기 순서"를 내어 준 것도 MAME 였습니다.

- https://www.mamedev.org/
- https://github.com/mamedev/mame

### 포함된 외부 코드

| 이름 | 용도 | 저자 | 라이선스 | 출처 (링크 + 커밋) | 사용한 파일 | 수정 여부 |
|---|---|---|---|---|---|---|
| Amber 2 (a23) | 메인 CPU (ARMv2a, 26 비트) | Conor Santifort / OpenCores | LGPL-2.1-or-later | [MiSTer-devel/Archie_MiSTer](https://github.com/MiSTer-devel/Archie_MiSTer) `rtl/amber` @ `7edeed510dbb80f505c1126b3a19b9416783989a` (원본: [opencores.org/projects/amber](https://opencores.org/projects/amber)) | `a23_core.v`, `a23_decode.v`, `a23_execute.v`, `a23_register_bank.v`, `a23_alu.v`, `a23_barrel_shift.v`, `a23_multiply.v`, `a23_coprocessor.v`, `a23_config_defines.v`, `a23_localparams.v`, `a23_functions.v`, `debug_functions.v` | **수정함** — `a23_core.v`: 캐시+Wishbone 전단(`a23_fetch`)을 이 기판의 메모리 프런트엔드로 교체, 디버그 포트 추가. `a23_execute.v`: 디버그 출력(PC, 모드). `a23_register_bank.v`: 레지스터 초기값을 0 으로, Archie 전용 디버그 인스턴스 제거. 변경 위치마다 `HVYSMSH:` 주석 |
| jt6295 | OKI MSM6295 ADPCM 두 개 | Jose Tejada Gomez (jotego) | GPL-3.0 | [jotego/jt6295](https://github.com/jotego/jt6295) @ `7d76b0be8cd8f85f3ae741178c9830b20e2071a1` | `jt6295.v`, `jt6295_acc.v`, `jt6295_adpcm.v`, `jt6295_ctrl.v`, `jt6295_rom.v`, `jt6295_serial.v`, `jt6295_sh_rst.v`, `jt6295_timing.v`, `jt12_comb.v` | 수정 없음 |
| jt9346 | 93C46 직렬 EEPROM | Jose Tejada Gomez (jotego) | GPL-3.0-or-later | [jotego/jteeprom](https://github.com/jotego/jteeprom) `hdl/jt9346.v` @ `9c68ce841f4ec560ca6f228c8af6301129fd95fa` | `jt9346.v` | 수정 없음 |
| MiSTer framework | HPS I/O, OSD, 스케일러, HDMI, 오디오 출력 | MiSTer-devel 과 기여자들 | 파일별 (대부분 GPL-2.0-or-later / GPL-3.0-or-later) | [MiSTer-devel/Template_MiSTer @ `54ac838e019d7fa07fbb40677a104cd6620d15c3` (2026-08-17, `sys/` 내용 일치로 식별)](https://github.com/MiSTer-devel/Template_MiSTer) | `sys/` 전체 | `sys.tcl` 의 경로 해석 두 줄만 수정 (공용 위치에서 `build_id.tcl`, `sys.qip` 를 찾도록). 동작 변화 없음 |

- **Conor Santifort** 님과 OpenCores 의 Amber 프로젝트, 그리고 Amber 를 MiSTer 에
  올려 실기에서 검증해 둔 **Archie_MiSTer** 기여자들께 감사드립니다. 실기에서
  돌아가는 26 비트 ARM 이 이미 있었기에 이 코어가 가능했습니다.
- **Jose Tejada Gomez (jotego)** 님께 감사드립니다. jt6295 는 MAME 의 OKI 모델과
  샘플 단위로 거의 완전히 일치했고, jt9346 은 그대로 끼워 넣기만 하면 됐습니다.
- **MiSTer-devel** 과 모든 기여자들께 감사드립니다. 이 플랫폼이 없었다면 시작할
  곳이 없었습니다.

그 밖의 모든 RTL — DE156 복호화, DECO 141 타일, DECO 52 스프라이트, DECO 56
그래픽 복호화, 버스, SDRAM 컨트롤러와 중재기, 사운드 믹서, ROM 다운로드 —
은 이 프로젝트에서 새로 작성했습니다. DE156·DECO 56 복호화의 상수와 표
(`deco56_*.hex`)는 MAME 소스의 데이터를 옮긴 것입니다.

### 참고한 MAME 소스

| MAME 파일 | 라이선스 | copyright-holders | 참고한 내용 |
|---|---|---|---|
| `src/mame/dataeast/hvysmsh.cpp` | BSD-3-Clause | Bryan McPhail | 드라이버 전체: 메모리 맵, 클럭, 인터럽트, 화면, 입력·EEPROM 포트, OKI 뱅크·사운드 게인, ROM 배치 |
| `src/mame/dataeast/deco156.cpp` | BSD-3-Clause | Bryan McPhail | DE156 프로그램 ROM 복호화 (주소 XOR 체인, 데이터 XOR·비트 순열) |
| `src/mame/dataeast/decocrpt.cpp` | BSD-3-Clause | Nicola Salmoria | DECO 56 그래픽 복호화 표 (주소·XOR·스왑) |
| `src/mame/dataeast/deco16ic.cpp` | BSD-3-Clause | Bryan McPhail | DECO 141 타일 생성기: 제어 레지스터, 타일 크기, 뱅크, 행·열 스크롤 |
| `src/mame/shared/decospr.cpp` | BSD-3-Clause | Bryan McPhail, David Haywood | DECO 52 스프라이트 리스트 포맷, 순회 순서, 우선순위 |
| `src/emu/drawgfx.cpp` | BSD-3-Clause | Nicola Salmoria, Aaron Giles | 투명 픽셀·플립 처리 규칙 |
| `src/devices/cpu/arm7/arm7.h` | BSD-3-Clause | Steve Ellenoff,R. Belmont,Ryan Holtz | DE156 이 26 비트 ARM2 라는 근거 |
| `src/devices/cpu/arm7/arm7.cpp` | BSD-3-Clause | Steve Ellenoff,R. Belmont,Ryan Holtz | DE156 의 아키텍처 플래그와 동작 차이 |
| `src/devices/sound/okim6295.h` | BSD-3-Clause | Mirko Buffoni,Aaron Giles | OKI 핀 7 설정과 샘플레이트 |
| `src/devices/machine/eeprom.cpp` | BSD-3-Clause | Aaron Giles | EEPROM 초기 상태와 동작 |

**FBNeo** (`d_deco156.cpp` 등) 는 MAME 에서 읽은 사실을 독립적으로 교차 확인하는
용도로만 읽었습니다 — 인터럽트 시점, 스프라이트 우선순위, 팔레트, 사운드
샘플 주소 처리 등. **FBNeo 의 코드는 한 줄도 가져오지 않았습니다.**

## 라이선스

이 코어 전체는 **GNU General Public License v3.0 (GPL-3.0)** 으로 배포합니다.
`LICENSE` 파일은 GPL-3.0 전문입니다.

포함된 외부 코드의 라이선스는 모두 GPL-3.0 과 함께 배포할 수 있습니다.

- jt6295 (GPL-3.0), jt9346 (GPL-3.0-or-later) — 그대로 호환됩니다.
- Amber a23 (LGPL-2.1-or-later) — LGPL-2.1 제3조가 GPL 로 바꿔 배포하는 것을
  명시적으로 허용합니다.
- MiSTer framework — 파일별 GPL-2.0-or-later / GPL-3.0-or-later 등.

외부 파일은 원래의 저작권·라이선스 헤더를 그대로 유지합니다. 수정한 Amber
파일에는 변경 위치마다 `HVYSMSH:` 주석이 붙어 있습니다.

**ROM 은 포함되어 있지 않으며, 이 저장소는 ROM 을 배포하지 않습니다.**
게임 ROM 은 정당하게 소유한 것을 직접 준비해 주세요.

## 알려진 제한사항

- **MiSTer 전용입니다.** Analogue Pocket 타깃은 아직 없습니다.
- 메인 CPU 는 25 MHz 로 돕니다 (MAME 가 쓰는 28 MHz 의 약 89 %). 게임 로직이
  VBlank 에 묶여 있어 실기에서 느려짐은 느끼지 못했지만, 원래 클럭은 아닙니다.
- DE156 의 코프로세서 0 명령(BCD 연산, 나눗셈·나머지)과 비정렬 `LDR PC` 의 올림
  동작은 구현되어 있지 않습니다. 확인된 플레이 구간에서는 쓰이지 않았습니다.
- **EEPROM 내용(게임 설정·기록)은 전원을 끄면 사라집니다.** 매번 새 기판처럼
  빈 EEPROM 으로 시작합니다.
- 사운드 재구성(선형 보간 + 프리엠퍼시스)과 VBlank 스프라이트 복사는 MAME 의
  결과에 맞춘 구현이며, 실제 기판의 회로를 그대로 옮긴 것은 아닙니다. 둘 다
  귀와 눈으로 수락했지만 샘플·픽셀 단위 대조는 아닙니다.
- 행 스크롤·열 스크롤·스프라이트의 "double wing" 속성은 구현은 되어 있지만,
  측정한 어트랙트와 경기 구간에서 게임이 쓰지 않아 실제로 검증되지는 않았습니다.
- 서비스 메뉴, 다른 캐릭터, 보너스 스테이지, 엔딩은 따로 검증하지 않았습니다.
  Asia·Japan 세트는 부팅과 어트랙트 데모까지만 확인했습니다.
- OSD 의 `Debug` 페이지에 개발용 항목(ROM 프로브, 디버그 오버레이)이 남아
  있습니다. 기본값은 둘 다 꺼짐입니다.
