class ReviewMeaningCandidate {
  const ReviewMeaningCandidate({
    required this.word,
    required this.meaning,
    this.partOfSpeech = '',
  });

  final String word;
  final String meaning;
  final String partOfSpeech;
}

typedef ReviewMeaningLoader = Future<List<ReviewMeaningCandidate>> Function({
  required String languageCode,
  required int seed,
  required int limit,
});
