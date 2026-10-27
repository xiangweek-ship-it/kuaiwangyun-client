import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'client_api.dart';

// 全局账户状态Provider
final accountProvider = StateProvider<ClientAccount?>((ref) {
  return null;
});

class AccountInfoWidget extends ConsumerWidget {
  const AccountInfoWidget({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final account = ref.watch(accountProvider);
    if (account == null) {
      return const SizedBox.shrink();
    }

    final isPermanent = (account.expiresAt?.year ?? 0) > 2099;
    final now = DateTime.now();
    final daysLeft = account.expiresAt?.difference(now).inDays ?? 0;
    final isExpiringSoon = !isPermanent && daysLeft <= 7;
    final isExpired = !isPermanent && daysLeft < 0;

    Color statusColor = Colors.green;
    IconData statusIcon = Icons.check_circle;
    String statusText = '正常';

    if (isExpired) {
      statusColor = Colors.red;
      statusIcon = Icons.error;
      statusText = '已过期';
    } else if (isExpiringSoon) {
      statusColor = Colors.orange;
      statusIcon = Icons.warning;
      statusText = '${daysLeft}天后到期';
    }

    return SizedBox(
      height: getWidgetHeight(2),
      child: RepaintBoundary(
        child: CommonCard(
          info: Info(
            label: '账户信息',
            iconData: Icons.account_circle,
          ),
          onPressed: () {},
          child: Padding(
            padding: baseInfoEdgeInsets.copyWith(top: 0),
            child: Column(
              mainAxisSize: MainAxisSize.max,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 用户名
                Row(
                  children: [
                    Icon(
                      statusIcon,
                      color: statusColor,
                      size: 16,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        account.username,
                        style: context.textTheme.titleSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: statusColor.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        statusText,
                        style: TextStyle(
                          fontSize: 11,
                          color: statusColor,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // 到期时间
                Row(
                  children: [
                    Icon(
                      Icons.access_time,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      size: 14,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      isPermanent
                          ? '永久会员'
                          : '到期: ${account.expiresAt?.toString().split(' ')[0] ?? '未知'}',
                      style: context.textTheme.bodySmall,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // 线路数量
                Row(
                  children: [
                    Icon(
                      Icons.route,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      size: 14,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '线路: ${account.sources.length}条',
                      style: context.textTheme.bodySmall,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
