import 'package:material_ui/material_ui.dart';

import 'admin_controller.dart';
import 'admin_mfa_page.dart';
import 'admin_theme.dart';

class AdminAuthPage extends StatelessWidget {
  const AdminAuthPage({super.key, required this.controller});
  final AdminController controller;

  @override
  Widget build(BuildContext context) {
    final stage = controller.stage;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: SelectionArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
            child: Column(
              children: [
                const AdminBrand(),
                const SizedBox(height: 40),
                if (stage == AdminStage.mfa)
                  AdminPanel(child: AdminMfaPage(controller: controller))
                else
                  AdminPanel(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          stage == AdminStage.denied ? '存取權限' : '管理者入口',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Semantics(
                          header: true,
                          child: Text(
                            stage == AdminStage.denied
                                ? '這個帳號沒有管理權限'
                                : stage == AdminStage.loading
                                ? '確認登入狀態'
                                : '登入管理介面',
                            style: text.headlineMedium,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          stage == AdminStage.denied
                              ? '請切換到已授權的 Google 帳號。若需要管理權限，請聯絡專案擁有者。'
                              : '使用已授權的 Google 帳號登入，再完成第二步驗證。',
                          style: text.bodyLarge,
                        ),
                        if (controller.access.email != null) ...[
                          const SizedBox(height: 16),
                          Text(
                            controller.access.email!,
                            style: text.bodyMedium,
                          ),
                        ],
                        const SizedBox(height: 28),
                        if (stage == AdminStage.loading)
                          const Center(
                            child: CircularProgressIndicator(
                              semanticsLabel: '確認登入狀態',
                            ),
                          )
                        else if (stage == AdminStage.denied)
                          OutlinedButton.icon(
                            onPressed: controller.busy
                                ? null
                                : controller.signOut,
                            icon: const Icon(Icons.logout),
                            label: const Text('登出並切換帳號'),
                          )
                        else if (stage == AdminStage.unavailable &&
                            controller.gateway != null) ...[
                          const AdminNotice('無法確認管理權限。請檢查連線後重試。', error: true),
                          const SizedBox(height: 16),
                          Wrap(
                            spacing: 12,
                            runSpacing: 8,
                            children: [
                              FilledButton(
                                onPressed: controller.refreshing
                                    ? null
                                    : controller.refresh,
                                child: const Text('重新確認'),
                              ),
                              if (controller.access.signedIn)
                                OutlinedButton(
                                  onPressed: controller.busy
                                      ? null
                                      : controller.signOut,
                                  child: const Text('登出'),
                                ),
                            ],
                          ),
                        ] else ...[
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              onPressed:
                                  controller.busy || controller.gateway == null
                                  ? null
                                  : controller.signIn,
                              icon: const Icon(Icons.login),
                              label: Text(
                                controller.busy
                                    ? '開啟 Google 登入中…'
                                    : '使用 Google 帳號登入',
                              ),
                            ),
                          ),
                          if (controller.gateway == null) ...[
                            const SizedBox(height: 16),
                            AdminNotice(
                              controller.configurationError ??
                                  '此管理站尚未連接登入服務，請聯絡專案擁有者完成設定。',
                            ),
                          ],
                          const SizedBox(height: 24),
                          const Divider(),
                          const SizedBox(height: 16),
                          const Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(Icons.verified_user_outlined, size: 20),
                              SizedBox(width: 10),
                              Expanded(
                                child: Text('第二步驗證可使用驗證器 App 或已登記的手機簡訊。'),
                              ),
                            ],
                          ),
                        ],
                        if (controller.error != null) ...[
                          const SizedBox(height: 20),
                          AdminNotice(controller.error!, error: true),
                        ],
                      ],
                    ),
                  ),
                const SizedBox(height: 24),
                Text(
                  '台灣機車停車指南 · 管理者專用',
                  style: text.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
