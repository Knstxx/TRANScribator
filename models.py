from dataclasses import dataclass


@dataclass(frozen=True)
class ModelOption:
    key: str
    model: str
    label: str


MODEL_OPTIONS = (
    ModelOption("g", "gpt-transcribe", "GPT Transcribe"),
    ModelOption("d", "gpt-4o-transcribe-diarize", "GPT-4o · говорящие"),
    ModelOption("w", "whisper-1", "Whisper · таймкоды"),
)

MODELS = {option.key: option.model for option in MODEL_OPTIONS}
