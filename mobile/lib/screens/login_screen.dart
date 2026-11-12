import 'package:flutter/material.dart';
import '../services/api.dart';
import '../services/app_state.dart';

class LoginScreen extends StatefulWidget {
  final AppState state;
  const LoginScreen({super.key, required this.state});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final form = GlobalKey<FormState>();
  final name = TextEditingController();
  final email = TextEditingController();
  final password = TextEditingController();
  final server = TextEditingController();
  bool registering = false;
  bool busy = false;
  String? error;
  @override
  void initState() {
    super.initState();
    server.text = widget.state.baseUrl;
  }

  @override
  void dispose() {
    name.dispose();
    email.dispose();
    password.dispose();
    server.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (!form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.state.setServer(server.text);
      server.text = widget.state.baseUrl;
      if (registering) {
        await widget.state.register(
          name.text.trim(),
          email.text.trim(),
          password.text,
        );
        if (!mounted) return;
        setState(() {
          registering = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Cadastro concluído. Agora entre com seu e-mail e senha.',
            ),
          ),
        );
      } else {
        await widget.state.login(email.text.trim(), password.text);
      }
    } on ApiError catch (exception) {
      if (mounted) {
        setState(() {
          error = exception.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          error =
              'Não foi possível conectar a ${widget.state.baseUrl}. '
              'Verifique se o backend está rodando, se o celular está na mesma '
              'rede Wi-Fi do computador e se as portas 8000 e 8001 estão '
              'liberadas no firewall.';
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
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Form(
              key: form,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Icon(Icons.eco, size: 64, color: Color(0xFF176B4A)),
                  Text(
                    'EcoPulse',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineLarge,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Observe sua região. Compartilhe riscos ambientais.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 28),
                  if (registering) ...[
                    TextFormField(
                      controller: name,
                      decoration: const InputDecoration(labelText: 'Nome'),
                      validator: (v) => (v?.trim().length ?? 0) < 2
                          ? 'Informe seu nome.'
                          : null,
                    ),
                    const SizedBox(height: 16),
                  ],
                  TextFormField(
                    controller: email,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(labelText: 'E-mail'),
                    validator: (v) =>
                        RegExp(
                          r'^[^\s@]+@[^\s@]+\.[^\s@]+$',
                        ).hasMatch(v?.trim() ?? '')
                        ? null
                        : 'Informe um e-mail válido.',
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: password,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'Senha'),
                    validator: (v) => (v?.length ?? 0) < (registering ? 8 : 1)
                        ? 'Use pelo menos ${registering ? 8 : 1} caracteres.'
                        : null,
                  ),
                  const SizedBox(height: 16),
                  if (error != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Text(
                        error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  FilledButton(
                    onPressed: busy ? null : submit,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        busy
                            ? 'Aguarde…'
                            : registering
                            ? 'Criar conta'
                            : 'Entrar',
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: busy
                        ? null
                        : () {
                            setState(() {
                              registering = !registering;
                              error = null;
                            });
                          },
                    child: Text(
                      registering ? 'Já tenho uma conta' : 'Criar uma conta',
                    ),
                  ),
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: const EdgeInsets.fromLTRB(2, 8, 2, 16),
                    title: const Text('Configuração da demonstração'),
                    children: [
                      TextFormField(
                        controller: server,
                        keyboardType: TextInputType.url,
                        decoration: const InputDecoration(
                          labelText: 'Endereço do servidor',
                          helperText:
                              'IP do computador na mesma rede Wi-Fi, porta 8000.\nEx.: http://192.168.0.10:8000',
                          helperMaxLines: 2,
                        ),
                      ),
                    ],
                  ),
                  if (widget.state.message != null) Text(widget.state.message!),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
