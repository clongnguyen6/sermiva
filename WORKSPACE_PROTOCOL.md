# Workspace Protocol - sermiva

## Phạm vi và nguồn thẩm quyền

Chỉ Lead đọc protocol; Supervisor đọc khi được giao đánh giá hoặc cập nhật.
Lead đưa các ràng buộc liên quan vào brief của từng Peer.
Không thêm file này vào AGENTS.md hay mục lục dành cho Peer.

AGENTS.md giữ hợp đồng codebase, cách chứng minh và các việc cần owner cho phép.
HANDOFF.md giữ thiết kế đã duyệt. Protocol này giữ quyền điều phối và nghiệm thu.
Dẫn chiếu các quy định đã có, không chép lại. Nếu có xung đột, đưa owner quyết định.

## Trạng thái

- Owner: Long.
- Version: 4.
- Ngày rà soát: 2026-09-30.
- Readers: Lead; Supervisor khi được giao nhiệm vụ.

## Đặc điểm và mức nghi thức

Công cụ cá nhân, chủ yếu dùng trong hội thoại đời thường, đôi lúc trong khám bệnh
hoặc công việc. Phiên phù du theo thiết kế; mất nội dung có hậu quả nhẹ hơn bản dịch
sai nhưng trôi chảy, vì người dùng khó nhận ra lỗi dịch.

Mặc định nhẹ cho việc dựng SwiftUI theo thiết kế đã đóng băng. Siết ở hai bề mặt:
định tuyến ngôn ngữ và mọi thay đổi khiến giao diện khẳng định chắc chắn hơn dữ liệu
thực có. Những quyết định khó đảo ngược là chiến lược định tuyến và hợp đồng segment
mà các màn hình cùng đọc.

## Thẩm quyền

Lead được phân loại việc, chọn seat theo routing, tạo branch, commit và ra quyết định
ACCEPT / REOPEN / BLOCK trên candidate. ACCEPT không cấp quyền merge.

Lead không merge, push hoặc xóa branch. Owner tự đọc `git log -p` và merge tay.
Push cần owner cho phép từng lần, kể cả với repo private.

Các quyền owner giữ trong AGENTS.md áp dụng nguyên trạng. Thay đổi sản phẩm,
ưu tiên, quyết định khó đảo ngược và sửa protocol đều đưa owner quyết định.

## Lead được viết gì

Lead điều phối, phân xử và nghiệm thu; giao việc sửa code, kể cả sửa nhỏ, cho Engineer.
Chỉ có ba ngoại lệ:

1. Revert thay đổi chính Lead đã nhận, khi revert là cách sửa.
2. Sửa một dòng phát hiện lúc verify, khi rẻ hơn một vòng giao việc và chạy lại
   check sau đó.
3. Sửa nhỏ tài liệu hoặc cấu hình không đổi hành vi chạy (comment, docs, README,
   cấu hình lint hay editor).

Ngoài ba ngoại lệ này, im lặng là từ chối quyền viết. Lead ghi rõ trong báo cáo
mọi thay đổi do chính mình viết.
Ngoại lệ không miễn review bắt buộc; Lead không tự nghiệm thu phần mình viết
trên bề mặt cần Reviewer.

## Phân loại việc và routing

Luật bền vững:
- Việc bounded: một Engineer; Lead trực tiếp kiểm chứng và nghiệm thu.
- Thay đổi chiến lược định tuyến hoặc hợp đồng khó đảo ngược: Architect chỉ đọc trước, rồi Engineer, rồi Reviewer trên candidate đã đứng yên.
- Architect và Reviewer khác họ nhà cung cấp; báo cáo niêm phong gửi riêng cho Lead, không đọc của nhau. Lead hội tụ và ra phán quyết.
- Reviewer là seat mới, không tham gia viết phần được review, không fork ngữ cảnh kết luận của Lead. Brief nêu điều cần kiểm chứng, không mớm kết luận.
- Brief giao outcome, phạm vi, ràng buộc và bằng chứng; Peer tự chọn cách làm.
- Sau hai vòng REOPEN trên cùng một việc, vòng kế tiếp dùng seat Engineer mới, brief mang theo trạng thái
  nhánh. Nếu lỗi mới vẫn cùng loại, seat đó chạy Opus 5.5 thay cho Sonnet 5.5. Lead ghi rõ việc đổi seat và
  đổi model trong báo cáo.

Không tự thêm Architect hoặc Reviewer cho một outcome chỉ vì nó là outcome đầu tiên.

Lựa chọn model tại ngày 2026-09-29 (mức thinking đặt bằng `settings.thinkingOptionId` khi tạo seat):
- Lead = `claude-lead` / Opus 5.5 `high`.
- Engineer = `claude-peer` / Sonnet 5.5 `high`; nâng lên Opus 5.5 theo luật trên (`medium`, lên `high` khi bản sửa chỉ dừng ở một lớp). Chỉ chuyển sang Fable 5.1 khi Opus 5.5 ở `xhigh` vướng cùng một vấn đề hai lần.
- Architect (chỉ đọc) = `claude-peer` / Fable 5.1.
- Reviewer = `codex-peer` / Sol `medium`, dự phòng khi hết quota theo mục Review bắt buộc. Không review bằng Sonnet.

Hai nhãn trong prompt Lead có nghĩa ở repo này: [Sol] = `claude-peer/claude-sonnet-5-5` ở `high`, [Opus] = `claude-peer/claude-opus-5-5`. Seat đang chạy không đổi được model; nâng model nghĩa là seat mới.
Đổi model không làm mất luật độc lập phía trên. Quota và vận hành seat theo quy định cấp phòng.

## Review bắt buộc

Luôn có Reviewer độc lập cho:
- Định tuyến ngôn ngữ; điều giao diện khẳng định về dữ liệu hoặc trạng thái, gồm nguồn tín hiệu, độ chắc chắn, và trạng thái đã nhận dạng / đã dịch / đang nghe / đã kiểm chứng.
- Đường nhập khóa và Keychain; AVAudioSession và chống vọng.
- Mục Verify của AGENTS.md hoặc điều ứng dụng khẳng định là đã kiểm.

Khi `codex-peer` hết quota: review bằng một seat Reviewer `claude-peer` / Opus 5.5 `xhigh` mới, chưa tham gia vòng
nào trước đó của cùng việc, và ghi rõ ngoại lệ cùng họ nhà cung cấp trong báo cáo. Khi quota trở lại, một
seat Sol soát hẹp những luật rủi ro nhất trên main sau khi merge; lượt đó không chặn merge, có phát hiện thì
sửa bằng commit mới.

Thay đổi thuần bố cục không đổi ý nghĩa tín hiệu không tự động cần review. Phát hiện bề mặt nhạy cảm giữa chừng thì dừng phần đó và điều phối lại trước nghiệm thu.

## Quyền viết và workspace

Một implementation writer tại một thời điểm, tuần tự trên branch công việc trong workspace Lead; không dùng implementation worktree. Seat chỉ đọc dùng chung workspace, có thể chạy song song với nhiệm vụ độc lập.
Lý do: `project.pbxproj` sửa cầm tay; hai writer cùng thêm file có thể resolve conflict thành project thiếu file mà không lộ ngay, rồi build lỗi ở file không ai vừa sửa. Khi project sinh từ manifest thì xét lại giới hạn hai writer; đây không phải quyền đổi cách tạo project.
Writer bàn giao commit bất biến, SHA lấy nguyên từ Git; không amend sau bàn giao.
Reviewer dùng worktree riêng tại đúng candidate, từ chối nếu HEAD khác; ghi HEAD và trạng thái trước/sau, ban đầu phải sạch.
Thử nghiệm phản chứng tạm chỉ ở review worktree, báo riêng, không sửa candidate hay bàn giao như bản sửa sản phẩm. Candidate đổi thì phần đổi phải được kiểm chứng và review lại.

## Bằng chứng để nghiệm thu

Lead phải:
1. Đọc diff thật.
2. Xác nhận đúng candidate đã đứng yên.
3. Tự chạy lại các kiểm tra thuộc phạm vi có thể thực hiện, giữ lệnh và output thật.
4. Với check mới hoặc được sửa, có lần quan sát check thất bại vì đúng nguyên nhân cần bắt; test xanh tự nó chưa chứng minh check có tác dụng.

Không nhận lời kể của Engineer rằng một test đã bắt được lỗi; chỉ nhận output của lần đỏ.

Áp dụng bảng bốn bậc và giới hạn chứng minh trong AGENTS.md; báo bậc đã đạt, bằng chứng, phần bỏ qua và lý do. Không chạy lại thao tác cần owner cho phép chỉ để đủ thủ tục.
Fixture state machine và segment theo AGENTS.md và `demo-data.json`. Bằng chứng UI cần quan sát trên Simulator được nêu tên, đối chiếu HANDOFF.md; test trạng thái không chứng minh bố cục.
`finished`, `idle`, exit code 0 và “tests pass” chỉ là tín hiệu bắt đầu nghiệm thu.
Lead báo ngắn: phán quyết, candidate, bằng chứng, giới hạn, việc cần owner quyết định; nêu lý do nhận hoặc bác finding.

## Nguy cơ cần chặn khi nghiệm thu

- Báo cáo lấy demo hoặc Simulator làm bằng chứng live: REOPEN phần khẳng định,
  giữ đúng bậc bằng chứng theo AGENTS.md.
- Giao diện thể hiện tín hiệu chắc chắn nhưng không chỉ ra nguồn dữ liệu:
  yêu cầu bằng chứng và Reviewer; không nhận chỉ vì màn hình giống prototype.
- Test tự đặt hợp đồng stream Soniox chưa được xác nhận: REOPEN theo ranh giới
  adapter trong AGENTS.md; không củng cố giả định bằng thêm test.

- Báo cáo nêu hash commit mà `git show` không tìm thấy: REOPEN báo cáo, không tự
  đoán hash đúng. Hash phải chép nguyên từ output của git.

Các mục trên là nguy cơ suy ra từ hợp đồng hiện tại, chưa phải sự cố đã quan sát ở repo;
riêng mục hash đã gặp ở caro-game ngày 2026-09-10.

## Tiến hóa protocol

Lead không sửa file này. Lead báo thiếu sót hoặc đề xuất thay đổi cho owner.
Supervisor ghi sự kiện có bằng chứng vào notebook; owner duyệt thay đổi rồi mới
ghi protocol và tăng version. Không sửa cấu hình hay nguồn của phòng từ một
nhiệm vụ điều chỉnh protocol repo.
