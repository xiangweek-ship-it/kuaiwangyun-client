import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/features/kuaiwangyun/account_info_widget.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/pages/home.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import 'client_api.dart';

class KuaiwangyunAccountGate extends ConsumerStatefulWidget {
  const KuaiwangyunAccountGate({super.key});
  @override
  ConsumerState<KuaiwangyunAccountGate> createState() =>
      _KuaiwangyunAccountGateState();
}

class _KuaiwangyunAccountGateState extends ConsumerState<KuaiwangyunAccountGate>
    with WidgetsBindingObserver {
  final _api = ClientApi();
  final _username = TextEditingController();
  final _password = TextEditingController();
  ClientAccount? _account;
  bool _busy = true;
  bool _refreshing = false;
  bool _obscure = true;
  bool _rememberMe = false;
  String? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
    _timer = Timer.periodic(const Duration(seconds: 60), (_) => _refresh());
  }

  Future<void> _init() async {
    // 加载记住的账号密码
    final creds = await _api.loadCredentials();
    if (creds != null) {
      _username.text = creds.username;
      _password.text = creds.password;
      _rememberMe = true;
    }
    await _restore();
  }

  bool _managed(Profile profile) {
    final uri = Uri.tryParse(profile.url);
    return uri?.host == 'kuaiwangyun.com' &&
        uri?.path == '/vpn/user/subscribe.php';
  }

  Future<void> _clearProfiles() async {
    if (!mounted) return;
    await ref.read(setupActionProvider.notifier).setRunning(false);
    for (final profile in List<Profile>.of(
      ref.read(profilesProvider),
    ).where(_managed)) {
      await ref.read(profilesActionProvider.notifier).deleteProfile(profile.id);
    }
  }

  Future<void> _restore() async {
    try {
      await ref.read(setupActionProvider.notifier).setRunning(false);
      if (await _api.restore()) await _accept(await _api.account(), sync: true);
    } catch (error) {
      await _handleError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _handleError(Object error) async {
    if (!mounted) return;
    final code = error is ClientApiException ? error.code : 'network_error';
    if (code == 'unauthorized') {
      await _clearProfiles();
      await _api.forget();
      _account = null;
    }
    if (mounted) setState(() => _error = code);
  }

  Future<void> _accept(ClientAccount account, {bool sync = false}) async {
    if (!mounted) return;
    setState(() {
      _account = account;
      _error = null;
    });
    // 同步到账户状态Provider
    ref.read(accountProvider.notifier).state = account;
    if (!account.canConnect) {
      await _clearProfiles();
      return;
    }
    final allowed = account.sources.map((s) => s.url).toSet();
    final obsolete = List<Profile>.of(
      ref.read(profilesProvider),
    ).where((p) => _managed(p) && !allowed.contains(p.url));
    for (final profile in obsolete) {
      await ref.read(profilesActionProvider.notifier).deleteProfile(profile.id);
    }
    if (sync) await _syncProfiles(account);
  }

  Future<void> _syncProfiles(ClientAccount account) async {
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (mounted &&
        (!ref.read(initProvider) ||
            ref.read(coreStatusProvider) != CoreStatus.connected)) {
      if (DateTime.now().isAfter(deadline)) {
        throw const ClientApiException('core_not_ready');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    if (!mounted) return;
    var failures = 0;
    var synced = 0;
    int? firstSyncedId;
    for (final source in account.sources) {
      if (!mounted || !account.canConnect) break;
      var completed = false;
      for (var attempt = 0; attempt < 3 && !completed; attempt++) {
        try {
          final existing = ref
              .read(profilesProvider)
              .where((p) => p.url == source.url)
              .firstOrNull;
          final base =
              (existing ?? Profile.normal(url: source.url, label: source.name))
                  .copyWith(label: source.name);
          final response = await _api.fetchSource(source);
          final updated = await base
              .copyWith(
                subscriptionInfo: SubscriptionInfo.formHString(
                  response.userInfo,
                ),
              )
              .saveFile(response.bytes);
          if (!mounted) return;
          ref.read(profilesActionProvider.notifier).putProfile(updated);
          firstSyncedId ??= updated.id;
          synced++;
          completed = true;
        } catch (_) {
          if (attempt < 2) {
            await Future<void>.delayed(Duration(seconds: attempt + 1));
          }
        }
      }
      if (!completed) failures++;
    }
    if (firstSyncedId != null) {
      final current = ref.read(currentProfileProvider);
      if (current == null || !_managed(current)) {
        ref.read(currentProfileIdProvider.notifier).value = firstSyncedId;
      }
      await ref
          .read(setupActionProvider.notifier)
          .applyProfile(force: true, silence: true);
    }
    if (mounted) {
      setState(() {
        _error = failures > 0 || synced == 0 ? 'partial_sync' : null;
      });
    }
  }

  Future<void> _login() async {
    if (_busy || _username.text.trim().isEmpty || _password.text.isEmpty) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final account = await _api.login(_username.text, _password.text);
      // 记住账号密码
      if (_rememberMe) {
        await _api.saveCredentials(_username.text, _password.text);
      } else {
        await _api.clearCredentials();
      }
      await _clearProfiles();
      await _accept(account, sync: true);
    } catch (error) {
      await _handleError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refresh({bool sync = false}) async {
    if (_account == null || _busy || _refreshing) return;
    _refreshing = true;
    if (sync && mounted) setState(() => _busy = true);
    try {
      if (!_account!.canConnect) {
        await _clearProfiles();
        if (mounted) setState(() {});
      }
      await _accept(await _api.account(), sync: sync);
    } catch (error) {
      await _handleError(error);
    } finally {
      _refreshing = false;
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _logout() async {
    if (_busy || _refreshing) return;
    setState(() => _busy = true);
    try {
      await _clearProfiles();
      await _api.logout();
    } catch (_) {
      await _api.forget();
    } finally {
      if (mounted) {
        setState(() {
          _account = null;
          _busy = false;
          _error = null;
        });
        // 清空账户状态
        ref.read(accountProvider.notifier).state = null;
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refresh());
  }

  String _message(BuildContext context) {
    final text = context.appLocalizations;
    return switch (_error) {
      'invalid_credentials' => text.kwInvalidCredentials,
      'rate_limited' => text.kwRateLimited,
      'unauthorized' => text.kwSessionExpired,
      'partial_sync' => text.kwPartialSync,
      'core_not_ready' => text.kwCoreNotReady,
      _ => text.kwNetworkError,
    };
  }

  Widget _notice(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Text(
      _message(context),
      style: TextStyle(color: Theme.of(context).colorScheme.error),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final text = context.appLocalizations;
    final account = _account;
    if (account != null && account.canConnect) {
      final isPermanent = account.expiresAt!.year > 2099;
      final expiresText = isPermanent
          ? '永久会员'
          : '${text.kwMembershipUntil} ${account.expiresAt!.toLocal().toIso8601String().substring(0, 10)}';
      return Column(
        children: [
          Container(
            color: Theme.of(context).colorScheme.surface,
            child: SafeArea(
              bottom: false,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      account.username,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                  if (isPermanent) ...[
                                    const SizedBox(width: 6),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF07C160).withValues(alpha: 0.1),
                                        borderRadius: BorderRadius.circular(3),
                                      ),
                                      child: const Text(
                                        '永久',
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: Color(0xFF07C160),
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(height: 2),
                              Text(
                                expiresText,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: text.kwSync,
                          onPressed: _busy ? null : () => _refresh(sync: true),
                          icon: Icon(
                            Icons.sync,
                            size: 18,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                          visualDensity: VisualDensity.compact,
                        ),
                        IconButton(
                          tooltip: text.kwLogout,
                          onPressed: _busy || _refreshing ? null : _logout,
                          icon: Icon(
                            Icons.logout,
                            size: 18,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ),
                  ),
                  Divider(
                    height: 1,
                    thickness: 0.5,
                    color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.3),
                  ),
                ],
              ),
            ),
          ),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null) _notice(context),
          if (account.sources.isEmpty)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(text.kwNoSources),
            ),
          const Expanded(child: HomePage()),
        ],
      );
    }
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Theme.of(context).colorScheme.primary.withValues(alpha: 0.05),
              Theme.of(context).colorScheme.surface,
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: AutofillGroup(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Logo
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.1),
                              blurRadius: 20,
                              offset: const Offset(0, 10),
                            ),
                          ],
                        ),
                        child: Image.asset('assets/images/kuaiwangyun.png', height: 60),
                      ),
                      const SizedBox(height: 32),
                      Text(
                        appName,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        text.kwWelcome,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 32),
                      if (account == null) ...[
                        // 用户名输入框
                        TextField(
                          controller: _username,
                          enabled: !_busy,
                          autofillHints: const [AutofillHints.username],
                          textInputAction: TextInputAction.next,
                          decoration: InputDecoration(
                            labelText: text.kwUsername,
                            prefixIcon: const Icon(Icons.person_outline),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            filled: true,
                            fillColor: Theme.of(context).colorScheme.surface,
                          ),
                        ),
                        const SizedBox(height: 16),
                        // 密码输入框
                        TextField(
                          controller: _password,
                          enabled: !_busy,
                          obscureText: _obscure,
                          autocorrect: false,
                          enableSuggestions: false,
                          autofillHints: const [AutofillHints.password],
                          onSubmitted: (_) => _login(),
                          decoration: InputDecoration(
                            labelText: text.kwPassword,
                            prefixIcon: const Icon(Icons.lock_outline),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            filled: true,
                            fillColor: Theme.of(context).colorScheme.surface,
                            suffixIcon: IconButton(
                              tooltip: text.kwShowPassword,
                              onPressed: () =>
                                  setState(() => _obscure = !_obscure),
                              icon: Icon(
                                _obscure
                                    ? Icons.visibility
                                    : Icons.visibility_off,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        // 记住我
                        Row(
                          children: [
                            Checkbox(
                              value: _rememberMe,
                              onChanged: _busy
                                  ? null
                                  : (v) => setState(() => _rememberMe = v ?? false),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                            Text(
                              '记住密码',
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),
                        // 登录按钮
                        FilledButton(
                          onPressed: _busy ? null : _login,
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.all(16),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: Text(
                            text.kwLogin,
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ] else ...[
                        Text(
                          text.kwMembershipRequired,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 16),
                        FilledButton(
                          onPressed: () => launchUrl(
                            Uri.parse('$clientWebsite/user/index.php'),
                            mode: LaunchMode.externalApplication,
                          ),
                          child: Text(text.kwRenew),
                        ),
                        OutlinedButton(
                          onPressed: _busy ? null : () => _refresh(sync: true),
                          child: Text(text.kwRefreshMembership),
                        ),
                        TextButton(
                          onPressed: _busy ? null : _logout,
                          child: Text(text.kwLogout),
                        ),
                      ],
                      if (_busy)
                        const Padding(
                          padding: EdgeInsets.all(16),
                          child: LinearProgressIndicator(),
                        ),
                      if (_error != null) _notice(context),
                      const SizedBox(height: 24),
                      TextButton(
                        onPressed: () => launchUrl(
                          Uri.parse('$clientWebsite/user/login.php'),
                          mode: LaunchMode.externalApplication,
                        ),
                        child: Text(text.kwAccountWebsite),
                      ),
                      Text(
                        text.kwPrivacy,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _api.close();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }
}
