import '../../../live_translated_text.dart';
import 'package:flutter/material.dart';

class EmptySearchState extends StatelessWidget {
  const EmptySearchState({super.key});

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: LiveTranslatedText('No Results Found'),
    );
  }
}