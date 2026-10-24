import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/database/collections/document.dart';
import '../../data/library_repository.dart';
import 'paper_preview.dart';

/// "New notebook" sheet: name + paper template + shade, then ONE repository
/// call (Document + first page land in a single Isar transaction).
Future<void> showCreateNotebookSheet(
  BuildContext context, {
  required int? folderId,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _CreateNotebookSheet(folderId: folderId),
  );
}

class _CreateNotebookSheet extends ConsumerStatefulWidget {
  const _CreateNotebookSheet({required this.folderId});

  final int? folderId;

  @override
  ConsumerState<_CreateNotebookSheet> createState() =>
      _CreateNotebookSheetState();
}

class _CreateNotebookSheetState extends ConsumerState<_CreateNotebookSheet> {
  final _titleController = TextEditingController();
  PaperTemplate _template = PaperTemplate.ruled;
  PaperShade _shade = PaperShade.light;
  bool _creating = false;

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (_creating) return;
    setState(() => _creating = true);
    final messenger = ScaffoldMessenger.maybeOf(context);
    final repo = await ref.read(libraryRepositoryProvider.future);
    final doc = await repo.createNotebook(
      folderId: widget.folderId,
      title: _titleController.text,
      template: _template,
      shade: _shade,
    );
    if (!mounted) return;
    Navigator.of(context).pop();
    messenger?.showSnackBar(
      SnackBar(content: Text('“${doc.title}” created')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('New notebook',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 14),
            TextField(
              controller: _titleController,
              autofocus: true,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Name',
                hintText: 'e.g. Pathology — Stage 3',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 18),
            Text('Paper',
                style: Theme.of(context)
                    .textTheme
                    .labelLarge
                    ?.copyWith(color: Theme.of(context).colorScheme.primary)),
            const SizedBox(height: 8),
            _TemplatePicker(
              template: _template,
              shade: _shade,
              onChanged: (t) => setState(() => _template = t),
            ),
            const SizedBox(height: 18),
            Text('Shade',
                style: Theme.of(context)
                    .textTheme
                    .labelLarge
                    ?.copyWith(color: Theme.of(context).colorScheme.primary)),
            const SizedBox(height: 8),
            SegmentedButton<PaperShade>(
              segments: const [
                ButtonSegment(value: PaperShade.light, label: Text('Light')),
                ButtonSegment(value: PaperShade.dark, label: Text('Dark')),
              ],
              selected: {_shade},
              onSelectionChanged: (s) => setState(() => _shade = s.first),
            ),
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _creating ? null : _create,
                icon: _creating
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add),
                label: Text(_creating ? 'Creating…' : 'Create'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TemplatePicker extends StatelessWidget {
  const _TemplatePicker({
    required this.template,
    required this.shade,
    required this.onChanged,
  });

  final PaperTemplate template;
  final PaperShade shade;
  final ValueChanged<PaperTemplate> onChanged;

  static const _labels = {
    PaperTemplate.ruled: 'Ruled',
    PaperTemplate.grid: 'Grid',
    PaperTemplate.dotted: 'Dotted',
    PaperTemplate.blank: 'Blank',
  };

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (final t in PaperTemplate.values)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: _TemplateOption(
                template: t,
                shade: shade,
                selected: t == template,
                onTap: () => onChanged(t),
                label: _labels[t]!,
              ),
            ),
          ),
      ],
    );
  }
}

class _TemplateOption extends StatelessWidget {
  const _TemplateOption({
    required this.template,
    required this.shade,
    required this.selected,
    required this.onTap,
    required this.label,
  });

  final PaperTemplate template;
  final PaperShade shade;
  final bool selected;
  final VoidCallback onTap;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Column(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            height: 84,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: selected ? scheme.primary : scheme.outlineVariant,
                width: selected ? 2.5 : 1,
              ),
            ),
            child: PaperPreview(
              template: template,
              shade: shade,
              cornerRadius: 9,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: selected ? scheme.primary : scheme.onSurfaceVariant,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
          ),
        ],
      ),
    );
  }
}
