"""NIGHTVOICE optional cloud response relay. Python 3.10+, FastAPI."""
import os
import re
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field
from openai import AsyncOpenAI

app = FastAPI(title="NIGHTVOICE response relay")
client = AsyncOpenAI(api_key=os.environ.get("OPENAI_API_KEY", ""))
MODEL = os.getenv("OPENAI_MODEL", "gpt-4o-mini")

class Exchange(BaseModel):
    question: str = Field(min_length=1, max_length=500)
    answer: str = Field(max_length=50)

class Question(BaseModel):
    question: str = Field(min_length=1, max_length=500)
    history: list[Exchange] = Field(default_factory=list, max_length=6)

@app.post("/respond")
async def respond(body: Question):
    if not os.getenv("OPENAI_API_KEY"):
        raise HTTPException(status_code=503, detail="Server AI key not configured")
    context = "\n".join(f"Q: {x.question}\nA: {x.answer}" for x in body.history)
    try:
        result = await client.chat.completions.create(
            model=MODEL,
            temperature=0.7,
            max_tokens=24,
            messages=[
                {"role": "system", "content": (
                    "You are a fictional spirit-box dialogue generator for an entertainment app. "
                    "Reply with ONLY one or two short words, no punctuation or explanation. "
                    "Make answers responsive to the current question and consistent with previous answers. "
                    "Never claim your responses are verified messages from the dead. "
                    "If uncertain, use 'Unknown' or 'Not sure'.")},
                {"role": "user", "content": f"Recent simulated dialogue:\n{context}\nQuestion: {body.question}"}
            ],
        )
        raw = result.choices[0].message.content or "Unknown"
        words = re.findall(r"[\w'-]+", raw, flags=re.UNICODE)[:2]
        return {"words": " ".join(words) or "Unknown", "source": "online"}
    except Exception:
        raise HTTPException(status_code=502, detail="Response provider unavailable")
