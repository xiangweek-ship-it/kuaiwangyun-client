import 'dart:async';

import 'package:fl_clash/common/common.dart';
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
  String? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _restore());
    _timer = Timer.periodic(const Duration(seconds: 60), (_) => _refresh());
  }

  bool _managed(Profile profile) {
    final uri = Uri.tryParse(profile.url);
    return uri?.host == 'kuaiwangyun.com' &&
        uri?.path == '/vpn/user/subscribe.php';
  }

  Future<void> _clearProfiles() async {
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
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    while (mounted && !ref.read(initProvider)) {
      if (DateTime.now().isAfter(deadline)) {
        throw const ClientApiException('core_not_ready');
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    if (!mounted) return;
    var failures = 0;
    for (final source in account.sources) {
      if (!mounted || !account.canConnect) break;
      try {
        final existing = ref
            .read(profilesProvider)
            .where((p) => p.url == source.url)
            .firstOrNull;
        final updated =
            await (existing ??
                    Profile.normal(url: source.url, label: source.name))
                .copyWith(label: source.name)
                .update();
        if (!mounted) return;
        ref.read(profilesActionProvider.notifier).putProfile(updated);
      } catch (_) {
        failures++;
      }
    }
    if (mounted) setState(() => _error = failures > 0 ? 'partial_sync' : null);
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
      _password.clear();
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
      return Column(
        children: [
          SafeArea(
            bottom: false,
            child: Material(
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Row(
                  children: [
                    Image.asset(
                      'assets/images/kuaiwangyun.png',
                      width: 30,
                      height: 30,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            account.username,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            '${text.kwMembershipUntil} ${account.expiresAt!.toLocal().toIso8601String().substring(0, 10)}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: text.kwSync,
                      onPressed: _busy ? null : () => _refresh(sync: true),
                      icon: const Icon(Icons.sync),
                    ),
                    IconButton(
                      tooltip: text.kwAccountWebsite,
                      onPressed: () => launchUrl(
                        Uri.parse('$clientWebsite/user/index.php'),
                        mode: LaunchMode.externalApplication,
                      ),
                      icon: const Icon(Icons.account_circle_outlined),
                    ),
                    IconButton(
                      tooltip: text.kwLogout,
                      onPressed: _busy || _refreshing ? null : _logout,
                      icon: const Icon(Icons.logout),
                    ),
                  ],
                ),
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
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: AutofillGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Image.asset('assets/images/kuaiwangyun.png', height: 80),
                    const SizedBox(height: 20),
                    Text(
                      appName,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(text.kwWelcome, textAlign: TextAlign.center),
                    const SizedBox(height: 28),
                    if (account == null) ...[
                      TextField(
                        controller: _username,
                        enabled: !_busy,
                        autofillHints: const [AutofillHints.username],
                        textInputAction: TextInputAction.next,
                        decoration: InputDecoration(
                          labelText: text.kwUsername,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 16),
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
                          border: const OutlineInputBorder(),
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
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: _busy ? null : _login,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(text.kwLogin),
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
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
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
