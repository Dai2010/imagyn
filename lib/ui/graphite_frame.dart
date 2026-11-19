// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 Kuimuztion
// 标题栏尺寸和颜色取自 GraphiteTraffic Thin 2.1 的 QML 装饰。

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../l10n/strings.dart';

class GraphiteFrame extends StatefulWidget {
  const GraphiteFrame({super.key, required this.child});
  final Widget child;

  @override
  State<GraphiteFrame> createState() => _GraphiteFrameState();
}

class _GraphiteFrameState extends State<GraphiteFrame> with WindowListener {
  bool active = true;
  bool maximized = false;
  bool fullscreen = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _readState();
  }

  Future<void> _readState() async {
    final state = await Future.wait([
      windowManager.isFocused(),
      windowManager.isMaximized(),
      windowManager.isFullScreen(),
    ]);
    if (!mounted) return;
    setState(() {
      active = state[0];
      maximized = state[1];
      fullscreen = state[2];
    });
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowFocus() => setState(() => active = true);
  @override
  void onWindowBlur() => setState(() => active = false);
  @override
  void onWindowMaximize() => setState(() => maximized = true);
  @override
  void onWindowUnmaximize() => setState(() => maximized = false);
  @override
  void onWindowEnterFullScreen() => setState(() => fullscreen = true);
  @override
  void onWindowLeaveFullScreen() => setState(() => fullscreen = false);

  Widget _lamp(String label, Color accent, String mark, VoidCallback action) {
    return Semantics(
      tooltip: label,
      label: label,
      child: TextButton(
        onPressed: action,
        style: ButtonStyle(
          padding: const WidgetStatePropertyAll(EdgeInsets.zero),
          minimumSize: const WidgetStatePropertyAll(Size(26, 25)),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            final show =
                states.contains(WidgetState.hovered) ||
                states.contains(WidgetState.focused) ||
                states.contains(WidgetState.pressed);
            return show ? const Color(0xff272727) : Colors.transparent;
          }),
        ),
        child: Container(
          width: 14,
          height: 14,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active ? accent : const Color(0xff626364),
          ),
          child: ExcludeSemantics(
            child: Text(mark, style: const TextStyle(fontSize: 11, height: 1)),
          ),
        ),
      ),
    );
  }

  Widget _caption() {
    final s = Strings.of(context);
    return Material(
      color: active ? const Color(0xff373737) : const Color(0xff2c2c2c),
      child: SizedBox(
        height: 27,
        child: Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              onSecondaryTap: windowManager.popUpWindowMenu,
              child: DragToMoveArea(
                child: Center(
                  child: Text(
                    'Imagyn',
                    style: TextStyle(
                      fontSize: 12,
                      color: active
                          ? const Color(0xffdedede)
                          : const Color(0xffacacac),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              right: 7,
              top: 1,
              child: Row(
                textDirection: TextDirection.ltr,
                children: [
                  _lamp(
                    s.t('minimize'),
                    const Color(0xfffebc2e),
                    '−',
                    windowManager.minimize,
                  ),
                  _lamp(
                    s.t(maximized ? 'restoreWindow' : 'maximize'),
                    const Color(0xff58c936),
                    maximized ? '▣' : '▴',
                    maximized
                        ? windowManager.unmaximize
                        : windowManager.maximize,
                  ),
                  _lamp(
                    s.t('close'),
                    const Color(0xfff4655f),
                    '×',
                    windowManager.close,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => VirtualWindowFrame(
    child: Column(
      children: [
        if (!fullscreen) _caption(),
        Expanded(child: widget.child),
      ],
    ),
  );
}
