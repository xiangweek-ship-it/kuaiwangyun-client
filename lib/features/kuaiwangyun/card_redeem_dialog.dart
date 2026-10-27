import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'client_api.dart';

class CardRedeemDialog extends StatefulWidget {
  const CardRedeemDialog({super.key});

  @override
  State<CardRedeemDialog> createState() => _CardRedeemDialogState();
}

class _CardRedeemDialogState extends State<CardRedeemDialog> {
  final _cardController = TextEditingController();
  bool _loading = false;
  String? _error;
  String? _success;

  @override
  void dispose() {
    _cardController.dispose();
    super.dispose();
  }

  Future<void> _redeem() async {
    final card = _cardController.text.trim();
    if (card.isEmpty) {
      setState(() => _error = '请输入卡密');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
      _success = null;
    });

    try {
      // 先从本地存储恢复 token，确保登录状态有效
      await globalClientApi.restore();
      final account = await globalClientApi.redeemCard(card);
      setState(() {
        _success = '兑换成功！\n会员到期时间：${account.expiresAt?.toString().split(' ')[0] ?? '永久'}';
      });
    } on ClientApiException catch (e) {
      setState(() {
        _error = _getErrorMessage(e.code);
      });
    } catch (e) {
      setState(() {
        _error = '兑换失败，请稍后重试';
      });
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  String _getErrorMessage(String code) {
    switch (code) {
      case 'invalid_card':
        return '卡密无效';
      case 'card_expired':
        return '卡密已过期';
      case 'card_used':
        return '卡密已被使用';
      case 'network_error':
        return '网络错误，请检查网络连接';
      case 'unauthorized':
        return '登录已过期，请重新登录';
      default:
        return '兑换失败：$code';
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.card_giftcard, color: Colors.green),
          SizedBox(width: 12),
          Text('卡密兑换'),
        ],
      ),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '请输入您的卡密，兑换会员时长',
              style: TextStyle(color: Colors.grey, fontSize: 14),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _cardController,
              decoration: InputDecoration(
                hintText: '请输入卡密',
                prefixIcon: const Icon(Icons.credit_card),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 14,
                ),
              ),
              enabled: !_loading,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9-]')),
              ],
              onSubmitted: (_) => _redeem(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  const Icon(Icons.error_outline, color: Colors.red, size: 16),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _error!,
                      style: const TextStyle(color: Colors.red, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ],
            if (_success != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.check_circle, color: Colors.green, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _success!,
                        style: const TextStyle(color: Colors.green, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _loading ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _loading ? null : _redeem,
          child: _loading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('兑换'),
        ),
      ],
    );
  }
}

// 显示卡密兑换对话框
void showCardRedeemDialog(BuildContext context) {
  showDialog(
    context: context,
    builder: (context) => const CardRedeemDialog(),
  );
}