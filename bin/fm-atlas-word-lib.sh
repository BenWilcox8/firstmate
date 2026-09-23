#!/usr/bin/env bash
# Parse the supported --captain-word option without letting a following option
# become the captain's words.
#
# Usage: fm_atlas_parse_captain_word <option> [<following-token>]
#
# `--captain-word=<words>` accepts any non-empty words, including words that
# start with a dash. `--captain-word <words>` requires a non-empty following
# token that does not start with a dash. On success, FM_ATLAS_CAPTAIN_WORD and
# FM_ATLAS_CAPTAIN_WORD_CONSUMED contain the words and consumed argument count.
# It returns 1 for a malformed supported form and 2 for another option.

fm_atlas_parse_captain_word() {
  local option=${1-} word
  case "$option" in
    --captain-word)
      [ "$#" -ge 2 ] || return 1
      word=$2
      case "$word" in
        ''|-*) return 1 ;;
      esac
      # shellcheck disable=SC2034
      FM_ATLAS_CAPTAIN_WORD=$word
      # shellcheck disable=SC2034
      FM_ATLAS_CAPTAIN_WORD_CONSUMED=2
      ;;
    --captain-word=*)
      word=${option#--captain-word=}
      [ -n "$word" ] || return 1
      # shellcheck disable=SC2034
      FM_ATLAS_CAPTAIN_WORD=$word
      # shellcheck disable=SC2034
      FM_ATLAS_CAPTAIN_WORD_CONSUMED=1
      ;;
    *) return 2 ;;
  esac
}
