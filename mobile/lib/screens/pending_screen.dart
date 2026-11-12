import 'dart:convert';
import 'package:flutter/material.dart';
import '../models/report.dart';
import '../services/app_state.dart';

const states = {
  'PENDING': 'Aguardando conexão',
  'SYNCING': 'Enviando',
  'QUEUED': 'Em processamento',
  'SYNCED': 'Processado',
  'FAILED': 'Falha no envio/processamento',
  'EXPIRED': 'Expirou',
  'RESOLVED': 'Resolvido',
};

class PendingScreen extends StatelessWidget {
  final AppState state;
  const PendingScreen({super.key, required this.state});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: const Text('Meus relatos'),
        actions: [
          IconButton(
            tooltip: 'Sincronizar',
            onPressed: state.syncing ? null : state.synchronize,
            icon: const Icon(Icons.sync),
          ),
        ],
      ),
      body: state.pending.isEmpty
          ? const Center(child: Text('Nenhum relato salvo neste aparelho.'))
          : ListView.builder(
              itemCount: state.pending.length,
              itemBuilder: (context, index) {
                final row = state.pending[index];
                final payload =
                    jsonDecode(row['payload'] as String)
                        as Map<String, dynamic>;
                return ListTile(
                  leading: Icon(
                    reportIcon(payload['type']),
                    color: reportColor(payload['type']),
                  ),
                  title: Text(reportLabels[payload['type']] ?? 'Ocorrência'),
                  subtitle: Text(
                    '${states[row['state']] ?? row['state']}\n${payload['description']}\n${row['error'] ?? ''}',
                  ),
                  isThreeLine: true,
                  trailing: row['state'] == 'FAILED'
                      ? IconButton(
                          tooltip: 'Tentar novamente',
                          icon: const Icon(Icons.refresh),
                          onPressed: state.syncing
                              ? null
                              : () => state.retry(row['id'] as String),
                        )
                      : row['state'] == 'SYNCED'
                      ? IconButton(
                          tooltip: 'Marcar como resolvido',
                          icon: const Icon(Icons.check_circle_outline),
                          onPressed: state.resolvingReports.contains(row['id'])
                              ? null
                              : () async {
                                  try {
                                    await state.resolveReport(
                                      row['id'] as String,
                                    );
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                            'Ocorrência marcada como resolvida.',
                                          ),
                                        ),
                                      );
                                    }
                                  } catch (error) {
                                    if (context.mounted) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            'Não foi possível encerrar. Confira a conexão e tente novamente. $error',
                                          ),
                                        ),
                                      );
                                    }
                                  }
                                },
                        )
                      : null,
                );
              },
            ),
    ),
  );
}
