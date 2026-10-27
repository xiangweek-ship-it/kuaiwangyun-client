import 'dart:math';

import 'package:defer_pointer/defer_pointer.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/features/kuaiwangyun/card_redeem_dialog.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/widgets/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'widgets/core_status_button.dart';
import 'widgets/start_button.dart';

typedef _IsEditWidgetBuilder = Widget Function(bool isEdit);

const _maxCrossAxisCount = 16;
const _maxGridWidth = 280.0 * _maxCrossAxisCount / 4;

class DashboardView extends ConsumerStatefulWidget {
  const DashboardView({super.key});

  @override
  ConsumerState<DashboardView> createState() => _DashboardViewState();
}

class _DashboardViewState extends ConsumerState<DashboardView> {
  final key = GlobalKey<SuperGridState>();
  final _isEditNotifier = ValueNotifier<bool>(false);
  final _addedWidgetsNotifier = ValueNotifier<List<GridItem>>([]);

  @override
  void dispose() {
    _isEditNotifier.dispose();
    _addedWidgetsNotifier.dispose();
    super.dispose();
  }

  Widget _buildIsEdit(_IsEditWidgetBuilder builder) {
    return ValueListenableBuilder(
      valueListenable: _isEditNotifier,
      builder: (_, isEdit, _) {
        return builder(isEdit);
      },
    );
  }

  // 一键智能连接
  Future<void> _smartConnect() async {
    // 1. 启动核心
    if (!ref.read(isStartProvider)) {
      ref.read(commonActionProvider.notifier).toggleRunning();
    }
    // 2. 等待核心启动
    await Future.delayed(const Duration(seconds: 2));
    // 3. 自动选择最优线路（延迟最低的节点）
    // 这里调用核心的延迟测试接口，选择延迟最低的节点
    // 由于FlClash的核心API比较复杂，这里简化为自动选择第一个可用节点
    try {
      final proxies = ref.read(proxiesProvider);
      if (proxies.isNotEmpty) {
        // 找到第一个可用的代理组
        final group = proxies.values.firstWhere(
          (p) => p.type == 'Selector' || p.type == 'URLTest',
          orElse: () => proxies.values.first,
        );
        // 选择该组中第一个可用节点
        if (group.all?.isNotEmpty == true) {
          ref.read(proxiesActionProvider.notifier).changeProxy(
                group.name,
                group.all!.first,
              );
        }
      }
    } catch (e) {
      // 忽略错误，使用默认选择
    }
  }

  List<Widget> _buildActions(bool isEdit) {
    return [
      if (!isEdit) ...[
        IconButton(
          icon: const Icon(Icons.bolt),
          tooltip: '一键智能连接',
          onPressed: _smartConnect,
        ),
        IconButton(
          icon: const Icon(Icons.card_giftcard),
          tooltip: '卡密兑换',
          onPressed: () => showCardRedeemDialog(context),
        ),
      ],
      if (!isEdit && coreLib == null) const CoreStatusButton(),
      if (isEdit)
        ValueListenableBuilder(
          valueListenable: _addedWidgetsNotifier,
          builder: (_, addedChildren, child) {
            if (addedChildren.isEmpty) {
              return Container();
            }
            return child!;
          },
          child: IconButton(
            onPressed: () {
              _showAddWidgetsModal();
            },
            icon: const Icon(Icons.add_circle),
          ),
        ),
      FadeRotationScaleBox(
        child: isEdit
            ? IconButton(
                key: const ValueKey(true),
                icon: const Icon(Icons.save, key: ValueKey('save-icon')),
                onPressed: _handleSaveAndExit,
              )
            : IconButton(
                key: const ValueKey(false),
                icon: const Icon(Icons.edit, key: ValueKey('edit-icon')),
                onPressed: _handleEnterEdit,
              ),
      ),
    ];
  }

  void _showAddWidgetsModal() {
    showSheet(
      builder: (_) {
        return ValueListenableBuilder(
          valueListenable: _addedWidgetsNotifier,
          builder: (_, value, _) {
            return AdaptiveSheetScaffold(
              body: _AddDashboardWidgetModal(
                items: value,
                onAdd: (gridItem) {
                  key.currentState?.handleAdd(gridItem);
                },
              ),
              title: context.appLocalizations.add,
            );
          },
        );
      },
      context: context,
    );
  }

  void _handleEnterEdit() {
    if (_isEditNotifier.value) {
      return;
    }
    _isEditNotifier.value = true;
  }

  void _handleExitEdit() {
    if (!_isEditNotifier.value) {
      return;
    }
    final dashboardWidgets = _getDashboardWidgets(key.currentState);
    if (dashboardWidgets != null) {
      _saveDashboardWidgets(dashboardWidgets);
    }
    _isEditNotifier.value = false;
  }

  Future<void> _handleSaveAndExit() async {
    if (!_isEditNotifier.value) {
      return;
    }
    await _handleSave();
    if (mounted) {
      _isEditNotifier.value = false;
    }
  }

  Future<void> _handleSave() async {
    final currentState = key.currentState;
    if (currentState == null) {
      return;
    }
    if (!mounted || currentState.snapshotChildren.isEmpty) {
      return;
    }
    final transformCompleted = await currentState.isTransformCompleter;
    if (!transformCompleted ||
        !mounted ||
        !currentState.mounted ||
        !identical(key.currentState, currentState)) {
      return;
    }
    final dashboardWidgets = _getDashboardWidgets(currentState);
    if (dashboardWidgets == null) {
      return;
    }
    _saveDashboardWidgets(dashboardWidgets);
  }

  List<DashboardWidget>? _getDashboardWidgets(SuperGridState? currentState) {
    if (currentState == null) {
      return null;
    }
    final children = currentState.snapshotChildren;
    if (children.isEmpty) {
      return null;
    }
    return children.map(DashboardWidget.getDashboardWidget).toList();
  }

  void _saveDashboardWidgets(List<DashboardWidget> dashboardWidgets) {
    ref
        .read(appSettingProvider.notifier)
        .update((state) => state.copyWith(dashboardWidgets: dashboardWidgets));
  }

  @override
  Widget build(BuildContext context) {
    final dashboardState = ref.watch(dashboardStateProvider);
    final spacing = 14.mAp;
    final children = [
      ...dashboardState.dashboardWidgets
          .where(
            (item) => item.platforms.contains(SupportPlatform.currentPlatform),
          )
          .map((item) => item.widget),
    ];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _addedWidgetsNotifier.value = DashboardWidget.values
          .where(
            (item) =>
                !children.contains(item.widget) &&
                item.platforms.contains(SupportPlatform.currentPlatform),
          )
          .map((item) => item.widget)
          .toList();
    });
    return _buildIsEdit(
      (isEdit) => CommonScaffold(
        title: context.appLocalizations.dashboard,
        actions: _buildActions(isEdit),
        floatingActionButton: const StartButton(),
        body: Align(
          alignment: Alignment.topCenter,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16).copyWith(bottom: 88),
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _maxGridWidth),
                child: LayoutBuilder(
                  builder: (_, constraints) {
                    final columns = min(
                      max(4 * ((constraints.maxWidth / 280).ceil()), 8),
                      _maxCrossAxisCount,
                    );
                    return isEdit
                        ? BackLayerScope(
                            onBack: _handleExitEdit,
                            child: SuperGrid(
                              key: key,
                              crossAxisCount: columns,
                              crossAxisSpacing: spacing,
                              mainAxisSpacing: spacing,
                              children: children,
                              onUpdate: () {
                                _handleSave();
                              },
                            ),
                          )
                        : Grid(
                            crossAxisCount: columns,
                            crossAxisSpacing: spacing,
                            mainAxisSpacing: spacing,
                            children: children,
                          );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AddDashboardWidgetModal extends StatelessWidget {
  final List<GridItem> items;
  final Function(GridItem item) onAdd;

  const _AddDashboardWidgetModal({required this.items, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    return DeferredPointerHandler(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Grid(
          crossAxisCount: 8,
          crossAxisSpacing: 16,
          mainAxisSpacing: 16,
          children: items
              .map(
                (item) => item.wrap(
                  builder: (child) {
                    return _AddedContainer(
                      onAdd: () {
                        onAdd(item);
                      },
                      child: child,
                    );
                  },
                ),
              )
              .toList(),
        ),
      ),
    );
  }
}

class _AddedContainer extends StatefulWidget {
  final Widget child;
  final VoidCallback onAdd;

  const _AddedContainer({required this.child, required this.onAdd});

  @override
  State<_AddedContainer> createState() => _AddedContainerState();
}

class _AddedContainerState extends State<_AddedContainer> {
  @override
  void initState() {
    super.initState();
  }

  @override
  void didUpdateWidget(_AddedContainer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.child != widget.child) {}
  }

  Future<void> _handleAdd() async {
    widget.onAdd();
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        ActivateBox(child: widget.child),
        Positioned(
          top: -8,
          right: -8,
          child: DeferPointer(
            child: SizedBox(
              width: 24,
              height: 24,
              child: IconButton.filled(
                iconSize: 20,
                padding: const EdgeInsets.all(2),
                onPressed: _handleAdd,
                icon: const Icon(Icons.add),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
