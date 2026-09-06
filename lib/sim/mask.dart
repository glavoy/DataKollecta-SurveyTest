/// The one reading of a `<mask>` this harness has.
///
/// `MaskedTextInputFormatter` in the app treats `[...]` as a character class
/// and everything else as a literal carried through. The respondent builds
/// values slot by slot on the same reading, and the lint counts slots on it,
/// so both agree with each other -- and, as far as a regex can, with the
/// widget.
class Mask {
  const Mask(this.pattern);

  final String pattern;

  static final RegExp _slots = RegExp(r'\[([^\]]+)\]|([^\[]+)');

  /// One entry per character the finished value will hold: a character class
  /// (without its brackets) or a literal string.
  List<MaskSlot> get slots => [
        for (final m in _slots.allMatches(pattern))
          if (m.group(1) != null)
            MaskSlot.charClass(m.group(1)!)
          else
            MaskSlot.literal(m.group(2)!),
      ];

  /// How many characters a value that fills every slot has.
  int get length => slots.fold(0, (n, s) => n + s.length);
}

class MaskSlot {
  const MaskSlot.charClass(this.charClass) : literal = null;
  const MaskSlot.literal(this.literal) : charClass = null;

  final String? charClass;
  final String? literal;

  int get length => literal?.length ?? 1;
}
