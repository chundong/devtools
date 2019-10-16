// Copyright 2019 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/// Inspector specific tree rendering support designed to be extendable to work
/// either directly with dart:html or with Hummingbird.
///
/// This library must not have direct dependencies on dart:html.
///
/// This allows tests of the complicated logic in this class to run on the VM
/// and will help simplify porting this code to work with Hummingbird.
library inspector_tree;

import 'dart:math' as math;

import 'package:meta/meta.dart';
import 'package:vm_service/vm_service.dart';

import '../config_specific/logger.dart';
import '../ui/fake_flutter/fake_flutter.dart';
import '../ui/icons.dart';
import '../ui/material_icons.dart';
import '../ui/theme.dart';
import '../utils.dart';
import 'diagnostics_node.dart';
import 'inspector_controller.dart';
import 'inspector_service.dart';
import 'inspector_text_styles.dart' as inspector_text_styles;

/// Split text into two groups, word characters at the start of a string and all
/// other characters.
final RegExp _primaryDescriptionPattern = RegExp(r'^([\w ]+)(.*)$');
// TODO(jacobr): temporary workaround for missing structure from assertion thrown building
// widget errors.
final RegExp _assertionThrownBuildingError = RegExp(
    r'^(The following assertion was thrown building [a-zA-Z]+)(\(.*\))(:)$');

final ColorIconMaker _colorIconMaker = ColorIconMaker();
final CustomIconMaker _customIconMaker = CustomIconMaker();

const bool _showRenderObjectPropertiesAsLinks = false;

typedef TreeEventCallback = void Function(InspectorTreeNode node);
typedef TreeHoverEventCallback = void Function(
  InspectorTreeNode node,
  DevToolsIcon icon,
);

const Color selectedRowBackgroundColor = ThemedColor(
  Color.fromARGB(255, 202, 191, 69),
  Color.fromARGB(255, 99, 101, 103),
);
const Color hoverColor = ThemedColor(
  Colors.yellowAccent,
  Color.fromARGB(255, 70, 73, 76),
);
const Color highlightLineColor = ThemedColor(
  Colors.black,
  Color.fromARGB(255, 200, 200, 200),
);
const Color defaultTreeLineColor = ThemedColor(
  Colors.grey,
  Color.fromARGB(255, 150, 150, 150),
);

const double iconPadding = 5.0;
const double chartLineStrokeWidth = 1.0;
const double columnWidth = 16.0;
const double verticalPadding = 10.0;
const double rowHeight = 24.0;
const Color arrowColor = Colors.grey;
final DevToolsIcon defaultIcon = _customIconMaker.fromInfo('Default');

// TODO(jacobr): these arrows are a bit ugly.
// We should create pngs instead of trying to stretch the material icons into
// being good expand collapse arrows.
const DevToolsIcon collapseArrow = MaterialIcon(
  'arrow_drop_down',
  arrowColor,
  fontSize: 32,
  iconWidth: columnWidth - iconPadding,
);

const DevToolsIcon expandArrow = MaterialIcon(
  'arrow_drop_down',
  arrowColor,
  fontSize: 32,
  angle: -math.pi / 2, // -90 degrees
  iconWidth: columnWidth - iconPadding,
);

abstract class PaintEntry {
  PaintEntry();

  DevToolsIcon get icon;

  void attach(InspectorTree owner) {}
}

abstract class InspectorTreeNodeRenderBuilder<
    R extends InspectorTreeNodeRender> {
  InspectorTreeNodeRenderBuilder({
    @required this.level,
    @required this.treeStyle,
  });
  void appendText(String text, TextStyle textStyle);
  void addIcon(DevToolsIcon icon);

  final DiagnosticLevel level;
  final DiagnosticsTreeStyle treeStyle;

  InspectorTreeNodeRender build();
}

abstract class InspectorTreeNodeRender<E extends PaintEntry> {
  InspectorTreeNodeRender(this.entries, this.size);

  final List<E> entries;
  final Size size;

  void attach(InspectorTree owner, Offset offset) {
    if (_owner != owner) {
      _owner = owner;
    }
    _offset = offset;

    for (var entry in entries) {
      entry.attach(owner);
    }
  }

  /// Offset can be updated after the object is created by calling attach
  /// with a new offset.
  Offset get offset => _offset;
  Offset _offset;

  InspectorTree _owner;

  Rect get paintBounds => _offset & size;

  PaintEntry hitTest(Offset location);
}

/// This class could be refactored out to be a reasonable generic collapsible
/// tree ui node class but we choose to instead make it widget inspector
/// specific as that is the only case we care about.
// TODO(kenz): extend TreeNode class to share tree logic.
abstract class InspectorTreeNode {
  InspectorTreeNode({
    InspectorTreeNode parent,
    bool expandChildren = true,
  })  : _children = <InspectorTreeNode>[],
        _parent = parent,
        _isExpanded = expandChildren;

  bool get showLinesToChildren {
    return _children.length > 1 && !_children.last.isProperty;
  }

  bool get isDirty => _isDirty;
  bool _isDirty = true;
  set isDirty(bool dirty) {
    if (dirty) {
      _renderObject = null;
      _isDirty = true;
      if (_childrenCount == null) {
        // Already dirty.
        return;
      }
      _childrenCount = null;
      if (parent != null) {
        parent.isDirty = true;
      }
    } else {
      _isDirty = false;
    }
  }

  bool selected = false;

  /// Override this method to define a tree node to build render objects
  /// appropriate for a specific platform.
  InspectorTreeNodeRenderBuilder createRenderBuilder();

  /// This method defines the logic of how a RenderObject is converted to
  /// a list of styled text and icons. If you want to change how tree content
  /// is styled modify this message as it is the robust way for style changes
  /// to apply to all ways inspector trees are rendered (html, canvas, Flutter
  /// in the future).
  /// If you change this rendering also change the matching logic in
  /// src/io/flutter/view/DiagnosticsTreeCellRenderer.java
  InspectorTreeNodeRender get renderObject {
    if (_renderObject != null || diagnostic == null) {
      return _renderObject;
    }

    final builder = createRenderBuilder();
    final icon = diagnostic.icon;
    if (showExpandCollapse) {
      builder.addIcon(isExpanded ? collapseArrow : expandArrow);
    }
    if (icon != null) {
      builder.addIcon(icon);
    }
    final String name = diagnostic.name;
    TextStyle textStyle = textStyleForLevel(diagnostic.level);
    if (diagnostic.isProperty) {
      // Display of inline properties.
      final String propertyType = diagnostic.propertyType;
      final Map<String, Object> properties = diagnostic.valuePropertiesJson;

      if (name?.isNotEmpty == true && diagnostic.showName) {
        builder.appendText('$name${diagnostic.separator} ', textStyle);
      }

      if (isCreatedByLocalProject) {
        textStyle = textStyle.merge(inspector_text_styles.regularBold);
      }

      String description = diagnostic.description;
      if (propertyType != null && properties != null) {
        switch (propertyType) {
          case 'Color':
            {
              final int alpha = JsonUtils.getIntMember(properties, 'alpha');
              final int red = JsonUtils.getIntMember(properties, 'red');
              final int green = JsonUtils.getIntMember(properties, 'green');
              final int blue = JsonUtils.getIntMember(properties, 'blue');
              String radix(int chan) => chan.toRadixString(16).padLeft(2, '0');
              if (alpha == 255) {
                description = '#${radix(red)}${radix(green)}${radix(blue)}';
              } else {
                description =
                    '#${radix(alpha)}${radix(red)}${radix(green)}${radix(blue)}';
              }

              final Color color = Color.fromARGB(alpha, red, green, blue);
              builder.addIcon(_colorIconMaker.getCustomIcon(color));
              break;
            }

          case 'IconData':
            {
              final int codePoint =
                  JsonUtils.getIntMember(properties, 'codePoint');
              if (codePoint > 0) {
                final DevToolsIcon icon =
                    FlutterMaterialIcons.getIconForCodePoint(codePoint);
                if (icon != null) {
                  builder.addIcon(icon);
                }
              }
              break;
            }
        }
      }

      if (_showRenderObjectPropertiesAsLinks &&
          propertyType == 'RenderObject') {
        textStyle = textStyle..merge(inspector_text_styles.link);
      }

      // TODO(jacobr): custom display for units, iterables, and padding.
      _renderDescription(builder, description, textStyle, isProperty: true);

      if (diagnostic.level == DiagnosticLevel.fine &&
          diagnostic.hasDefaultValue) {
        builder.appendText(' ', textStyle);
        builder.addIcon(defaultIcon);
      }
    } else {
      // Non property, regular node case.
      if (name?.isNotEmpty == true && diagnostic.showName && name != 'child') {
        if (name.startsWith('child ')) {
          builder.appendText(name, inspector_text_styles.unimportant);
        } else {
          builder.appendText(name, textStyle);
        }

        if (diagnostic.showSeparator) {
          builder.appendText(
              diagnostic.separator, inspector_text_styles.unimportant);
          if (diagnostic.separator != ' ' &&
              diagnostic.description.isNotEmpty) {
            builder.appendText(' ', inspector_text_styles.unimportant);
          }
        }
      }

      if (!diagnostic.isSummaryTree && diagnostic.isCreatedByLocalProject) {
        textStyle = textStyle.merge(inspector_text_styles.regularBold);
      }

      _renderDescription(builder, diagnostic.description, textStyle,
          isProperty: false);
    }
    _renderObject = builder.build();
    return _renderObject;
  }

  InspectorTreeNodeRender _renderObject;
  RemoteDiagnosticsNode _diagnostic;
  final List<InspectorTreeNode> _children;

  Iterable<InspectorTreeNode> get children => _children;

  bool get isCreatedByLocalProject => _diagnostic.isCreatedByLocalProject;
  bool get isProperty => diagnostic == null || diagnostic.isProperty;

  bool get isExpanded => _isExpanded;
  bool _isExpanded;

  bool allowExpandCollapse = true;

  bool get showExpandCollapse {
    return (diagnostic?.hasChildren == true || children.isNotEmpty) &&
        allowExpandCollapse;
  }

  set isExpanded(bool value) {
    if (value != _isExpanded) {
      _isExpanded = value;
      isDirty = true;
    }
  }

  InspectorTreeNode get parent => _parent;
  InspectorTreeNode _parent;

  set parent(InspectorTreeNode value) {
    _parent = value;
    _parent?.isDirty = true;
  }

  RemoteDiagnosticsNode get diagnostic => _diagnostic;

  set diagnostic(RemoteDiagnosticsNode v) {
    _diagnostic = v;
    _isExpanded = v.childrenReady;
    isDirty = true;
  }

  int get childrenCount {
    if (!isExpanded) {
      _childrenCount = 0;
    }
    if (_childrenCount != null) {
      return _childrenCount;
    }
    int count = 0;
    for (InspectorTreeNode child in _children) {
      count += child.subtreeSize;
    }
    _childrenCount = count;
    return _childrenCount;
  }

  bool get hasPlaceholderChildren {
    return children.length == 1 && children.first.diagnostic == null;
  }

  int _childrenCount;

  int get subtreeSize => childrenCount + 1;

  bool get isLeaf => _children.isEmpty;

  // TODO(jacobr): move getRowIndex to the InspectorTree class.
  int getRowIndex(InspectorTreeNode node) {
    int index = 0;
    while (true) {
      final InspectorTreeNode parent = node.parent;
      if (parent == null) {
        break;
      }
      for (InspectorTreeNode sibling in parent._children) {
        if (sibling == node) {
          break;
        }
        index += sibling.subtreeSize;
      }
      index += 1; // For parent itself.
      node = parent;
    }
    return index;
  }

  // TODO(jacobr): move this method to the InspectorTree class.
  // TODO: optimize this method.
  /// Use [getCachedRow] wherever possible, as [getRow] is slow and can cause
  /// performance problems.
  InspectorTreeRow getRow(int index) {
    final List<int> ticks = <int>[];
    InspectorTreeNode node = this;
    if (subtreeSize <= index) {
      return null;
    }
    int current = 0;
    int depth = 0;
    while (node != null) {
      final style = node.diagnostic?.style;
      final bool indented = style != DiagnosticsTreeStyle.flat &&
          style != DiagnosticsTreeStyle.error;
      if (current == index) {
        return InspectorTreeRow(
          node: node,
          index: index,
          ticks: ticks,
          depth: depth,
          lineToParent:
              !node.isProperty && index != 0 && node.parent.showLinesToChildren,
        );
      }
      assert(index > current);
      current++;
      final List<InspectorTreeNode> children = node._children;
      int i;
      for (i = 0; i < children.length; ++i) {
        final child = children[i];
        final subtreeSize = child.subtreeSize;
        if (current + subtreeSize > index) {
          node = child;
          if (children.length > 1 &&
              i + 1 != children.length &&
              !children.last.isProperty) {
            if (indented) {
              ticks.add(depth);
            }
          }
          break;
        }
        current += subtreeSize;
      }
      assert(i < children.length);
      if (indented) {
        depth++;
      }
    }
    assert(false); // internal error.
    return null;
  }

  void removeChild(InspectorTreeNode child) {
    child.parent = null;
    final removed = _children.remove(child);
    assert(removed != null);
    isDirty = true;
  }

  void appendChild(InspectorTreeNode child) {
    _children.add(child);
    child.parent = this;
    isDirty = true;
  }

  void clearChildren() {
    _children.clear();
    isDirty = true;
  }

  void _renderDescription(
    InspectorTreeNodeRenderBuilder<InspectorTreeNodeRender<PaintEntry>> builder,
    String description,
    TextStyle textStyle, {
    bool isProperty,
  }) {
    if (diagnostic.isDiagnosticableValue) {
      final match = _primaryDescriptionPattern.firstMatch(description);
      if (match != null) {
        builder.appendText(match.group(1), textStyle);
        if (match.group(2).isNotEmpty) {
          builder.appendText(match.group(2), inspector_text_styles.unimportant);
        }
        return;
      }
    } else if (diagnostic.type == 'ErrorDescription') {
      final match = _assertionThrownBuildingError.firstMatch(description);
      if (match != null) {
        builder.appendText(match.group(1), textStyle);
        builder.appendText(match.group(3), textStyle);
        return;
      }
    }
    if (description?.isNotEmpty == true) {
      builder.appendText(description, textStyle);
    }
  }
}

/// A row in the tree with all information required to render it.
class InspectorTreeRow {
  const InspectorTreeRow({
    @required this.node,
    @required this.index,
    @required this.ticks,
    @required this.depth,
    @required this.lineToParent,
  });

  final InspectorTreeNode node;

  /// Column indexes of ticks to draw lines from parents to children.
  final List<int> ticks;
  final int depth;
  final int index;
  final bool lineToParent;

  bool get isSelected => node.selected;
}

typedef InspectorTreeFactory = InspectorTree Function({
  @required bool summaryTree,
  @required FlutterTreeType treeType,
  @required NodeAddedCallback onNodeAdded,
  VoidCallback onSelectionChange,
  TreeEventCallback onExpand,
  TreeHoverEventCallback onHover,
});

/// Callback issued every time a node is added to the tree.
typedef NodeAddedCallback = void Function(
    InspectorTreeNode node, RemoteDiagnosticsNode diagnosticsNode);

abstract class InspectorTree {
  InspectorTree({
    @required this.summaryTree,
    @required this.treeType,
    @required NodeAddedCallback onNodeAdded,
    VoidCallback onSelectionChange,
    this.onExpand,
    TreeHoverEventCallback onHover,
  })  : _onHoverCallback = onHover,
        _onSelectionChange = onSelectionChange,
        _onNodeAdded = onNodeAdded;

  final TreeHoverEventCallback _onHoverCallback;

  final TreeEventCallback onExpand;

  final VoidCallback _onSelectionChange;

  final NodeAddedCallback _onNodeAdded;

  InspectorTreeNode get root => _root;
  InspectorTreeNode _root;
  set root(InspectorTreeNode node) {
    setState(() {
      _root = node;
    });
  }

  RemoteDiagnosticsNode subtreeRoot; // Optional.

  InspectorTreeNode get selection => _selection;
  InspectorTreeNode _selection;

  set selection(InspectorTreeNode node) {
    if (node == _selection) return;

    setState(() {
      _selection?.selected = false;
      _selection = node;
      _selection?.selected = true;
      if (_onSelectionChange != null) {
        _onSelectionChange();
      }
    });
  }

  InspectorTreeNode get hover => _hover;
  InspectorTreeNode _hover;

  final bool summaryTree;

  final FlutterTreeType treeType;

  double lastContentWidth;

  void setState(VoidCallback modifyState);
  InspectorTreeNode createNode();

  final List<InspectorTreeRow> cachedRows = [];

  // TODO: we should add a listener instead that clears the cache when the
  // root is marked as dirty.
  void _maybeClearCache() {
    if (root.isDirty) {
      cachedRows.clear();
      root.isDirty = false;
      lastContentWidth = null;
    }
  }

  InspectorTreeRow getCachedRow(int index) {
    _maybeClearCache();
    while (cachedRows.length <= index) {
      cachedRows.add(null);
    }
    cachedRows[index] ??= root.getRow(index);
    return cachedRows[index];
  }

  double getRowOffset(int index) {
    return (getCachedRow(index)?.depth ?? 0) * columnWidth;
  }

  set hover(InspectorTreeNode node) {
    if (node == _hover) {
      return;
    }
    setState(() {
      _hover = node;
      // TODO(jacobr): we could choose to repaint only a portion of the UI
    });
  }

  String get tooltip;
  set tooltip(String value);

  RemoteDiagnosticsNode _currentHoverDiagnostic;
  bool _computingHover = false;

  void navigateUp() {
    _navigateHelper(-1);
  }

  void navigateDown() {
    _navigateHelper(1);
  }

  void navigateLeft() {
    // This logic is consistent with how IntelliJ handles tree navigation on
    // on left arrow key press.
    if (selection == null) {
      _navigateHelper(-1);
      return;
    }

    if (selection.isExpanded) {
      setState(() {
        selection.isExpanded = false;
      });
      return;
    }
    if (selection.parent != null) {
      selection = selection.parent;
    }
  }

  void navigateRight() {
    // This logic is consistent with how IntelliJ handles tree navigation on
    // on right arrow key press.

    if (selection == null || selection.isExpanded) {
      _navigateHelper(1);
      return;
    }

    setState(() {
      selection.isExpanded = true;
    });
  }

  void _navigateHelper(int indexOffset) {
    if (numRows == 0) return;

    if (selection == null) {
      selection = root;
      return;
    }

    selection = root
        .getRow(
            (root.getRowIndex(selection) + indexOffset).clamp(0, numRows - 1))
        ?.node;
  }

  Future<void> onHover(InspectorTreeNode node, PaintEntry entry) async {
    if (_onHoverCallback != null) {
      _onHoverCallback(node, entry?.icon);
    }

    final diagnostic = node?.diagnostic;
    final lastHover = _currentHoverDiagnostic;
    _currentHoverDiagnostic = diagnostic;
    // Only show tooltips when we are hovering over specific content in a row
    // rather than over the entire row.
    // TODO(jacobr): consider showing the tooltip any time we are on a row with
    // a diagnostics node to make tooltips more discoverable.
    // To make this work well we would need to add custom tooltip rendering that
    // more clearly links tooltips to the exact content in a row they apply to.
    if (diagnostic == null || entry == null) {
      tooltip = '';
      _computingHover = false;
      return;
    }

    if (entry.icon == defaultIcon) {
      tooltip = 'Default value';
      _computingHover = false;
      return;
    }

    if (diagnostic.isEnumProperty()) {
      // We can display a better tooltip than the one provied with the
      // RemoteDiagnosticsNode as we have access to introspection
      // via the vm service.

      if (lastHover == diagnostic && _computingHover) {
        // No need to spam the VMService. We are already computing the hover
        // for this node.
        return;
      }
      _computingHover = true;
      Map<String, InstanceRef> properties;
      try {
        properties = await diagnostic.valueProperties;
      } finally {
        _computingHover = false;
      }
      if (lastHover != diagnostic) {
        // Skipping as the tooltip is no longer relevant for the currently
        // hovered over node.
        return;
      }
      if (properties == null) {
        // Something went wrong getting the enum value.
        // Fall back to the regular tooltip;
        tooltip = diagnostic.tooltip;
        return;
      }
      tooltip = 'Allowed values:\n${properties.keys.join('\n')}';
      return;
    }

    tooltip = diagnostic.tooltip;
    _computingHover = false;
  }

  double get horizontalPadding => 10.0;

  double getDepthIndent(int depth) {
    return (depth + 1) * columnWidth + horizontalPadding;
  }

  double getRowY(int index) {
    return rowHeight * index + verticalPadding;
  }

  void nodeChanged(InspectorTreeNode node) {
    if (node == null) return;
    setState(() {
      node.isDirty = true;
    });
  }

  void removeNodeFromParent(InspectorTreeNode node) {
    setState(() {
      node.parent?.removeChild(node);
    });
  }

  void appendChild(InspectorTreeNode node, InspectorTreeNode child) {
    setState(() {
      node.appendChild(child);
    });
  }

  void expandPath(InspectorTreeNode node) {
    setState(() {
      _expandPath(node);
    });
  }

  void _expandPath(InspectorTreeNode node) {
    while (node != null) {
      if (!node.isExpanded) {
        node.isExpanded = true;
      }
      node = node.parent;
    }
  }

  void collapseToSelected() {
    setState(() {
      _collapseAllNodes(root);
      if (selection == null) return;
      _expandPath(selection);
    });
  }

  void _collapseAllNodes(InspectorTreeNode root) {
    root.isExpanded = false;
    root.children.forEach(_collapseAllNodes);
  }

  int get numRows => root != null ? root.subtreeSize : 0;

  int getRowIndex(double y) => (y - verticalPadding) ~/ rowHeight;

  InspectorTreeRow getRowForNode(InspectorTreeNode node) {
    return getCachedRow(root.getRowIndex(node));
  }

  InspectorTreeRow getRow(Offset offset) {
    if (root == null) return null;
    final int row = getRowIndex(offset.dy);
    return row < root.subtreeSize ? getCachedRow(row) : null;
  }

  void animateToTargets(List<InspectorTreeNode> targets);

  void onTap(Offset offset) {
    final row = getRow(offset);
    if (row == null) {
      return;
    }

    onTapIcon(row, row.node.renderObject?.hitTest(offset)?.icon);
  }

  void onTapIcon(InspectorTreeRow row, DevToolsIcon icon) {
    if (icon == expandArrow) {
      setState(() {
        row.node.isExpanded = true;
        if (onExpand != null) {
          onExpand(row.node);
        }
      });
      return;
    }
    if (icon == collapseArrow) {
      setState(() {
        row.node.isExpanded = false;
      });
      return;
    }
    // TODO(jacobr): add other interactive elements here.
    selection = row.node;
    expandPath(row.node);
  }

  bool expandPropertiesByDefault(DiagnosticsTreeStyle style) {
    // This code matches the text style defaults for which styles are
    //  by default and which aren't.
    switch (style) {
      case DiagnosticsTreeStyle.none:
      case DiagnosticsTreeStyle.singleLine:
      case DiagnosticsTreeStyle.errorProperty:
        return false;

      case DiagnosticsTreeStyle.sparse:
      case DiagnosticsTreeStyle.offstage:
      case DiagnosticsTreeStyle.dense:
      case DiagnosticsTreeStyle.transition:
      case DiagnosticsTreeStyle.error:
      case DiagnosticsTreeStyle.whitespace:
      case DiagnosticsTreeStyle.flat:
      case DiagnosticsTreeStyle.shallow:
      case DiagnosticsTreeStyle.truncateChildren:
        return true;
    }
    return true;
  }

  InspectorTreeNode setupInspectorTreeNode(
    InspectorTreeNode node,
    RemoteDiagnosticsNode diagnosticsNode, {
    @required bool expandChildren,
    @required bool expandProperties,
  }) {
    assert(expandChildren != null);
    assert(expandProperties != null);
    node.diagnostic = diagnosticsNode;
    if (_onNodeAdded != null) {
      _onNodeAdded(node, diagnosticsNode);
    }

    if (diagnosticsNode.hasChildren ||
        diagnosticsNode.inlineProperties.isNotEmpty) {
      if (diagnosticsNode.childrenReady || !diagnosticsNode.hasChildren) {
        final bool styleIsMultiline =
            expandPropertiesByDefault(diagnosticsNode.style);
        setupChildren(
          diagnosticsNode,
          node,
          node.diagnostic.childrenNow,
          expandChildren: expandChildren && styleIsMultiline,
          expandProperties: expandProperties && styleIsMultiline,
        );
      } else {
        node.clearChildren();
        node.appendChild(createNode());
      }
    }
    return node;
  }

  void setupChildren(
    RemoteDiagnosticsNode parent,
    InspectorTreeNode treeNode,
    List<RemoteDiagnosticsNode> children, {
    @required bool expandChildren,
    @required bool expandProperties,
  }) {
    assert(expandChildren != null);
    assert(expandProperties != null);
    treeNode.isExpanded = expandChildren;
    if (treeNode.children.isNotEmpty) {
      // Only case supported is this is the loading node.
      assert(treeNode.children.length == 1);
      removeNodeFromParent(treeNode.children.first);
    }
    final inlineProperties = parent.inlineProperties;

    if (inlineProperties != null) {
      for (RemoteDiagnosticsNode property in inlineProperties) {
        appendChild(
          treeNode,
          setupInspectorTreeNode(
            createNode(),
            property,
            // We are inside a property so only expand children if
            // expandProperties is true.
            expandChildren: expandProperties,
            expandProperties: expandProperties,
          ),
        );
      }
    }
    if (children != null) {
      for (RemoteDiagnosticsNode child in children) {
        appendChild(
          treeNode,
          setupInspectorTreeNode(
            createNode(),
            child,
            expandChildren: expandChildren,
            expandProperties: expandProperties,
          ),
        );
      }
    }
  }

  Future<void> maybePopulateChildren(InspectorTreeNode treeNode) async {
    final RemoteDiagnosticsNode diagnostic = treeNode.diagnostic;
    if (diagnostic != null &&
        diagnostic.hasChildren &&
        (treeNode.hasPlaceholderChildren || treeNode.children.isEmpty)) {
      try {
        final children = await diagnostic.children;
        if (treeNode.hasPlaceholderChildren || treeNode.children.isEmpty) {
          setupChildren(
            diagnostic,
            treeNode,
            children,
            expandChildren: true,
            expandProperties: false,
          );
          nodeChanged(treeNode);
          if (treeNode == selection) {
            expandPath(treeNode);
          }
        }
      } catch (e) {
        log(e.toString(), LogLevel.error);
      }
    }
  }
}

abstract class InspectorTreeFixedRowHeight extends InspectorTree {
  InspectorTreeFixedRowHeight({
    @required bool summaryTree,
    @required FlutterTreeType treeType,
    @required NodeAddedCallback onNodeAdded,
    VoidCallback onSelectionChange,
    TreeEventCallback onExpand,
    TreeHoverEventCallback onHover,
  }) : super(
          summaryTree: summaryTree,
          treeType: treeType,
          onNodeAdded: onNodeAdded,
          onSelectionChange: onSelectionChange,
          onExpand: onExpand,
          onHover: onHover,
        );

  Rect getBoundingBox(InspectorTreeRow row);

  void scrollToRect(Rect targetRect);

  /// The future completes when the possible tooltip on hover is available.
  ///
  /// Generally only await this future for tests that check for the value shown
  /// on hover matches the expected value.
  Future<void> onMouseMove(Offset offset) async {
    final row = getRow(offset);
    if (row != null) {
      final node = row.node;
      await onHover(node, node?.renderObject?.hitTest(offset));
    } else {
      await onHover(null, null);
    }
  }

  @override
  void animateToTargets(List<InspectorTreeNode> targets) {
    Rect targetRect;

    for (InspectorTreeNode target in targets) {
      final row = getRowForNode(target);
      if (row != null) {
        final rowRect = getBoundingBox(row);
        targetRect =
            targetRect == null ? rowRect : targetRect.expandToInclude(rowRect);
      }
    }

    if (targetRect == null || targetRect.isEmpty) return;

    targetRect = targetRect.inflate(20.0);
    scrollToRect(targetRect);
  }
}