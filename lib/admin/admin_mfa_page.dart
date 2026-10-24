import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_ui/material_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'admin_controller.dart';
import 'admin_theme.dart';

class AdminMfaPage extends StatefulWidget {
  const AdminMfaPage({
    super.key,
    required this.controller,
    this.settings = false,
  });
  final AdminController controller;
  final bool settings;

  @override
  State<AdminMfaPage> createState() => _AdminMfaPageState();
}

class _AdminMfaPageState extends State<AdminMfaPage> {
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _code = TextEditingController();
  final _enrollKey = GlobalKey<FormState>();
  final _verifyKey = GlobalKey<FormState>();
  FactorType _type = FactorType.totp;
  bool _adding = false;
  bool _showSecret = false;
  String? _previousFactor;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final text = Theme.of(context).textTheme;
    if (_previousFactor != c.activeFactorId) {
      _code.clear();
      _showSecret = false;
      _previousFactor = c.activeFactorId;
    }
    final enrolling = c.enrollment != null;
    final canEnroll = widget.settings || c.verifiedFactors.isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.settings ? '帳號安全' : '第二步驗證',
          style: TextStyle(
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 12),
        Semantics(
          header: true,
          child: Text(
            widget.settings ? '管理驗證方式' : '請先完成第二步驗證',
            style: text.headlineMedium,
          ),
        ),
        const SizedBox(height: 12),
        Text(c.access.email ?? '管理者帳號', style: text.bodyMedium),
        const SizedBox(height: 24),
        if (c.authenticatorCount < 2) ...[
          const AdminNotice('請至少登記兩個驗證器 App，例如手機與密碼管理器，互為備援。每個驗證器請分別登記。'),
          const SizedBox(height: 24),
        ],
        if (!c.refreshing && !enrolling && c.unfinishedFactors.isNotEmpty) ...[
          Semantics(
            header: true,
            child: Text('未完成的登記', style: text.titleMedium),
          ),
          const SizedBox(height: 8),
          const Text('若曾中斷設定，可先取消尚未驗證的登記，再使用相同名稱重新登記。'),
          for (final factor in c.unfinishedFactors)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 12,
                runSpacing: 4,
                children: [
                  Text(
                    factor.friendlyName ??
                        (factor.factorType == FactorType.phone
                            ? '手機簡訊'
                            : '驗證器 App'),
                  ),
                  TextButton.icon(
                    key: ValueKey('discard/${factor.id}'),
                    onPressed: c.busy
                        ? null
                        : () => c.discardUnfinished(factor.id),
                    icon: const Icon(Icons.close),
                    label: const Text('取消登記'),
                  ),
                ],
              ),
            ),
          const Divider(),
          const SizedBox(height: 24),
        ],
        if (c.refreshing) ...[
          const LinearProgressIndicator(semanticsLabel: '讀取驗證方式'),
          const SizedBox(height: 16),
        ] else if (!enrolling &&
            c.verifiedFactors.isNotEmpty &&
            !(_adding && widget.settings)) ...[
          if (widget.settings) ...[
            Text('已登記的驗證方式', style: text.titleMedium),
            const SizedBox(height: 8),
            for (final factor in c.verifiedFactors)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  factor.factorType == FactorType.phone
                      ? Icons.sms_outlined
                      : Icons.phonelink_lock,
                ),
                title: Text(
                  factor.friendlyName ??
                      (factor.factorType == FactorType.phone
                          ? '手機簡訊'
                          : '驗證器 App'),
                ),
                subtitle: const Text('已驗證'),
              ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: c.busy ? null : () => setState(() => _adding = true),
              icon: const Icon(Icons.add),
              label: const Text('登記另一個驗證方式'),
            ),
          ] else ...[
            DropdownButtonFormField<String>(
              key: ValueKey(c.selectedFactorId),
              initialValue: c.selectedFactorId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '選擇驗證方式'),
              items: [
                for (final factor in c.verifiedFactors)
                  DropdownMenuItem(
                    value: factor.id,
                    child: Text(
                      factor.friendlyName ??
                          (factor.factorType == FactorType.phone
                              ? '手機簡訊'
                              : '驗證器 App'),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: c.busy
                  ? null
                  : (value) {
                      if (value != null) c.selectFactor(value);
                    },
            ),
            const SizedBox(height: 20),
            _verification(c),
          ],
        ] else if (enrolling) ...[
          Text('驗證新登記的方式', style: text.titleLarge),
          const SizedBox(height: 12),
          if (c.enrollment!.totp case final totp?) ...[
            const Text('使用驗證器 App 掃描 QR code，或手動輸入設定密鑰。'),
            const SizedBox(height: 16),
            Center(
              child: Container(
                color: AdminColors.white,
                padding: const EdgeInsets.all(16),
                child: SvgPicture.string(
                  totp.qrCode.startsWith('data:')
                      ? totp.qrCode.substring(totp.qrCode.indexOf(',') + 1)
                      : totp.qrCode,
                  width: 200,
                  height: 200,
                  semanticsLabel: '新驗證器的登記 QR code',
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              key: ValueKey(c.enrollment!.id),
              initialValue: totp.secret,
              readOnly: true,
              obscureText: !_showSecret,
              enableSuggestions: false,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: '設定密鑰',
                suffixIcon: IconButton(
                  tooltip: _showSecret ? '隱藏密鑰' : '顯示密鑰',
                  onPressed: () => setState(() => _showSecret = !_showSecret),
                  icon: Icon(
                    _showSecret
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
          ],
          if (c.enrollment!.phone != null) ...[
            Text('傳送驗證碼至 ${c.enrollment!.phone!.phone}，完成手機登記。'),
            const SizedBox(height: 16),
          ],
          _verification(c),
          const SizedBox(height: 8),
          TextButton(
            onPressed: c.busy
                ? null
                : () async {
                    await c.cancelEnrollment();
                    if (mounted && c.enrollment == null) {
                      setState(() => _adding = false);
                    }
                  },
            child: const Text('取消這次登記'),
          ),
        ] else if (canEnroll) ...[
          Form(
            key: _enrollKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('登記驗證方式', style: text.titleLarge),
                const SizedBox(height: 16),
                DropdownButtonFormField<FactorType>(
                  initialValue: _type,
                  decoration: const InputDecoration(labelText: '驗證方式'),
                  items: const [
                    DropdownMenuItem(
                      value: FactorType.totp,
                      child: Text('驗證器 App（建議）'),
                    ),
                    DropdownMenuItem(
                      value: FactorType.phone,
                      child: Text('手機簡訊（選用）'),
                    ),
                  ],
                  onChanged: c.busy
                      ? null
                      : (value) => setState(() => _type = value!),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _name,
                  maxLength: 64,
                  enabled: !c.busy,
                  decoration: const InputDecoration(
                    labelText: '方便辨識的名稱',
                    hintText: '例如：手機驗證器',
                  ),
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? '請輸入驗證方式的名稱' : null,
                ),
                if (_type == FactorType.phone) ...[
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _phone,
                    enabled: !c.busy,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      labelText: '手機號碼（含國碼）',
                      hintText: '+886912345678',
                    ),
                    validator: (v) =>
                        RegExp(r'^\+[1-9]\d{6,14}$').hasMatch(v?.trim() ?? '')
                        ? null
                        : '請輸入含國碼的完整手機號碼，例如 +886912345678',
                  ),
                  const SizedBox(height: 12),
                  const Text('簡訊需由專案擁有者先啟用，可能產生電信費用。'),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: c.busy || c.refreshing
                      ? null
                      : () {
                          if (_enrollKey.currentState!.validate()) {
                            c.enroll(
                              _type,
                              _name.text.trim(),
                              _type == FactorType.phone
                                  ? _phone.text.trim()
                                  : null,
                            );
                          }
                        },
                  child: Text(c.busy ? '登記中…' : '開始登記'),
                ),
                if (widget.settings && c.verifiedFactors.isNotEmpty)
                  TextButton(
                    onPressed: c.busy
                        ? null
                        : () => setState(() => _adding = false),
                    child: const Text('返回已登記的方式'),
                  ),
              ],
            ),
          ),
        ],
        if (c.error != null) ...[
          const SizedBox(height: 20),
          AdminNotice(c.error!, error: true),
        ],
        const SizedBox(height: 24),
        const Divider(),
        const SizedBox(height: 12),
        Text('若所有驗證方式都已遺失，請聯絡專案擁有者協助重設。', style: text.bodySmall),
        if (!widget.settings) ...[
          const SizedBox(height: 12),
          TextButton.icon(
            onPressed: c.busy ? null : c.signOut,
            icon: const Icon(Icons.logout),
            label: const Text('登出'),
          ),
        ],
      ],
    );
  }

  Widget _verification(AdminController c) => Form(
    key: _verifyKey,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (c.activeFactorType == FactorType.phone) ...[
          OutlinedButton.icon(
            onPressed: c.busy ? null : c.sendChallenge,
            icon: const Icon(Icons.sms_outlined),
            label: Text(c.challenge == null ? '傳送簡訊驗證碼' : '重新傳送簡訊'),
          ),
          const SizedBox(height: 12),
          if (c.challenge != null) ...[
            Semantics(liveRegion: true, child: const Text('驗證碼已傳送，請查看手機簡訊。')),
            const SizedBox(height: 12),
          ],
        ] else ...[
          const Text('輸入驗證器 App 顯示的 6 位數驗證碼。'),
          const SizedBox(height: 12),
        ],
        TextFormField(
          controller: _code,
          enabled: !c.busy,
          keyboardType: TextInputType.number,
          autofillHints: const [AutofillHints.oneTimeCode],
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(6),
          ],
          decoration: const InputDecoration(labelText: '6 位數驗證碼'),
          validator: (v) =>
              RegExp(r'^\d{6}$').hasMatch(v ?? '') ? null : '請輸入完整的 6 位數驗證碼',
          onFieldSubmitted: (_) => _verify(c),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed:
              c.busy ||
                  (c.activeFactorType == FactorType.phone &&
                      c.challenge == null)
              ? null
              : () => _verify(c),
          child: Text(c.busy ? '驗證中…' : '確認驗證碼'),
        ),
      ],
    ),
  );

  Future<void> _verify(AdminController c) async {
    if (c.busy || !_verifyKey.currentState!.validate()) return;
    await c.verify(_code.text);
    if (mounted && c.enrollment == null && c.stage == AdminStage.ready) {
      _code.clear();
      _name.clear();
      _phone.clear();
      setState(() => _adding = false);
    }
  }
}
