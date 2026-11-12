import 'package:flutter/material.dart';
import '../models/report.dart';
import '../services/app_state.dart';

class ReportScreen extends StatefulWidget {
  final AppState state;
  const ReportScreen({super.key, required this.state});
  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  final description = TextEditingController();
  String type = 'FLOOD';
  bool busy = false;
  String? error;
  @override
  void dispose() {
    description.dispose();
    super.dispose();
  }

  Future<void> save() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.state.createReport(type, description.text);
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Relato salvo. Acompanhe o envio em “Meus relatos”.'),
        ),
      );
    } catch (exception) {
      if (mounted) {
        setState(() {
          error = exception.toString();
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Registrar ocorrência')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          'Registre o que você está observando neste local. O GPS será consultado ao salvar.',
        ),
        const SizedBox(height: 24),
        DropdownButtonFormField<String>(
          value: type,
          decoration: const InputDecoration(labelText: 'Tipo de ocorrência'),
          items: reportLabels.entries
              .map(
                (entry) => DropdownMenuItem(
                  value: entry.key,
                  child: Text(entry.value),
                ),
              )
              .toList(),
          onChanged: busy
              ? null
              : (value) {
                  setState(() {
                    type = value!;
                  });
                },
        ),
        const SizedBox(height: 20),
        TextField(
          controller: description,
          maxLength: 500,
          minLines: 3,
          maxLines: 5,
          decoration: const InputDecoration(
            labelText: 'Descrição (opcional)',
            hintText: 'Ex.: rua alagada perto do ponto de ônibus',
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'Sem conexão, o relato fica salvo neste aparelho até a sincronização. A validade começa no horário da observação.',
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: busy ? null : save,
          icon: const Icon(Icons.add_location_alt),
          label: Text(busy ? 'Obtendo GPS e salvando…' : 'Salvar relato'),
        ),
      ],
    ),
  );
}
